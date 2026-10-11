import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The result of a [DiskImageCache.fetch] call.
class DiskImageCacheResult {
  /// Creates a [DiskImageCacheResult].
  const DiskImageCacheResult({
    required this.file,
    required this.downloaded,
    required this.modified,
  });

  /// The cached file on disk.
  final File file;

  /// Whether the cache downloaded the file during this call, or during the
  /// in-flight download that this call joined.
  ///
  /// It is `false` for a cache hit. Waiters that join an in-flight download
  /// share the result of the call that started it, so they also report
  /// `true`.
  final bool downloaded;

  /// The modification time of [file] when the call produced this result.
  ///
  /// A fresh download usually reports a newer value than the file it replaced,
  /// so callers can tell refreshed bytes at the same path apart. File system
  /// timestamp granularity can make the new value equal to the previous one,
  /// so a TTL below that tick can miss the refresh.
  final DateTime modified;
}

/// A disk-backed cache for network images.
///
/// The cache stores files in a dedicated folder and names each file by the
/// `cacheKey` passed to [fetch]. The cache reuses a file until [evict] or
/// [clear] removes it, or until the file is older than the `maxAge` given to
/// [fetch].
///
/// The internal HTTP client lives for the lifetime of the cache instance. The
/// cache never closes it. Share one [DiskImageCache] instance across many
/// images so that its client can pool connections.
class DiskImageCache {
  /// Creates a [DiskImageCache].
  ///
  /// The cache uses the [client] to download images. When [client] is
  /// omitted, the cache creates its own [http.Client] on first use. The cache
  /// does not close the client, so callers share one cache instance.
  ///
  /// The [directoryProvider] returns the base directory that contains the
  /// cache folder. It defaults to [getApplicationDocumentsDirectory].
  ///
  /// The [folderName] is the name of the cache folder inside the base
  /// directory. It must follow the same rules as a cache key.
  ///
  /// The [timeout] is the maximum time to wait for the HTTP response.
  DiskImageCache({
    http.Client? client,
    Future<Directory> Function()? directoryProvider,
    this.folderName = 'disk_cached_image',
    this.timeout = const Duration(seconds: 30),
  }) : _providedClient = client,
       _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory {
    _validateKey(folderName, 'folderName');
  }

  final http.Client? _providedClient;
  final Future<Directory> Function() _directoryProvider;

  /// Name of the folder that stores the cached files.
  final String folderName;

  /// The maximum time to wait for the HTTP response.
  ///
  /// Only the future returned by [fetch] times out. The cache does not abort
  /// the underlying HTTP request when the timeout elapses.
  final Duration timeout;

  late final http.Client _client = _providedClient ?? http.Client();

  static final Map<String, Future<DiskImageCacheResult>> _inFlight = {};

  static int _tempCounter = 0;

  static final RegExp _validKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  static final RegExp _tempFilePattern = RegExp(r'\.tmp-\d+-\d+$');

  static const int _maxKeyLength = 128;

  static const Set<String> _reservedDeviceNames = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  /// Downloads [url] and stores it on disk under [cacheKey].
  ///
  /// Returns a [DiskImageCacheResult] whose [DiskImageCacheResult.downloaded]
  /// is `true` when this call downloaded the file or joined an in-flight
  /// download, and `false` for a cache hit.
  ///
  /// A download only happens when no file exists for [cacheKey], or when the
  /// existing file is older than [maxAge]. With a `null` [maxAge], the cache
  /// keeps the file until eviction.
  ///
  /// The cache identifies a file by [cacheKey] only, never by [url]. When the
  /// URL for a key changes, the cache still serves the cached bytes. Callers
  /// must [evict] the key or use a distinct key for each URL.
  ///
  /// Overlapping calls for the same [cacheKey] share a single download and
  /// receive the same result. The returned future times out with a
  /// `TimeoutException` after [timeout]. The cache does not abort the
  /// underlying HTTP request.
  ///
  /// Throws an [ArgumentError] when [cacheKey] is invalid. Throws an
  /// [HttpException] when the server responds with a status code other than
  /// 200.
  Future<DiskImageCacheResult> fetch({
    required Uri url,
    required String cacheKey,
    Duration? maxAge,
  }) async {
    _validateKey(cacheKey, 'cacheKey');
    final file = await _fileFor(cacheKey);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.notFound) {
      if (maxAge == null ||
          DateTime.now().difference(stat.modified) <= maxAge) {
        return DiskImageCacheResult(
          file: file,
          downloaded: false,
          modified: stat.modified,
        );
      }
    }
    final path = file.path;
    final inFlight = _inFlight[path];
    if (inFlight != null) return inFlight;
    final tracked = _download(url: url, destination: file).whenComplete(() {
      _inFlight.remove(path);
    });
    _inFlight[path] = tracked;
    return tracked;
  }

  /// Deletes the cached file stored under [cacheKey].
  ///
  /// Does nothing when no file exists for [cacheKey]. Throws an
  /// [ArgumentError] when [cacheKey] is invalid.
  Future<void> evict(String cacheKey) async {
    _validateKey(cacheKey, 'cacheKey');
    final file = await _fileFor(cacheKey);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Deletes the whole cache folder and every file in it.
  Future<void> clear() async {
    final directory = await _cacheDirectory();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  /// Returns the total size of all cached files in bytes.
  ///
  /// The cache does not count temporary files from interrupted downloads.
  /// Returns `0` when the cache folder does not exist.
  Future<int> size() async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && !_isTempFile(entity)) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<Directory> _cacheDirectory() async {
    final base = await _directoryProvider();
    return Directory('${base.path}/$folderName');
  }

  Future<File> _fileFor(String cacheKey) async {
    final directory = await _cacheDirectory();
    return File('${directory.path}/$cacheKey');
  }

  static void _validateKey(String key, String name) {
    final stem = key.split('.').first.toUpperCase();
    if (key.isEmpty ||
        key.length > _maxKeyLength ||
        key.endsWith('.') ||
        !_validKey.hasMatch(key) ||
        _reservedDeviceNames.contains(stem)) {
      throw ArgumentError.value(
        key,
        name,
        'must be 1 to $_maxKeyLength characters, start with a letter or '
        'digit, contain only letters, digits, ".", "_" and "-", must not '
        'end with ".", and must not be a Windows reserved device name',
      );
    }
  }

  static bool _isTempFile(File file) {
    final segments = file.uri.pathSegments;
    final name = segments.isEmpty ? file.path : segments.last;
    return _tempFilePattern.hasMatch(name);
  }

  Future<DiskImageCacheResult> _download({
    required Uri url,
    required File destination,
  }) async {
    final response = await _client.get(url).timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException(
        'Request to $url failed with status ${response.statusCode}.',
        uri: url,
      );
    }
    await destination.parent.create(recursive: true);
    final tempFile = File(
      '${destination.path}.tmp-${_tempCounter++}-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tempFile.writeAsBytes(response.bodyBytes, flush: true);
      await _replace(tempFile, destination);
    } catch (_) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    }
    final stat = await destination.stat();
    return DiskImageCacheResult(
      file: destination,
      downloaded: true,
      modified: stat.modified,
    );
  }

  static Future<void> _replace(File source, File destination) async {
    try {
      await source.rename(destination.path);
      return;
    } on FileSystemException {
      if (!await source.exists()) {
        if (await destination.exists()) return;
        rethrow;
      }
      if (await destination.exists()) {
        await destination.delete();
      }
      await source.rename(destination.path);
    }
  }
}
