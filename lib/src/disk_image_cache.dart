import 'dart:async';
import 'dart:convert';
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
    this.refresh,
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

  /// The background refresh started by a stale-while-revalidate fetch.
  ///
  /// It resolves to the refreshed result, or to the stale result when the
  /// refresh fails. It is null for every other call.
  final Future<DiskImageCacheResult>? refresh;
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
    this.maxBytes,
    DateTime Function()? clock,
  }) : _providedClient = client,
       _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory,
       _clock = clock ?? DateTime.now {
    _validateKey(folderName, 'folderName');
  }

  final http.Client? _providedClient;
  final Future<Directory> Function() _directoryProvider;
  final DateTime Function() _clock;

  /// The soft limit of the stored bytes.
  ///
  /// After a download, the cache deletes least-recently-used entries until the
  /// stored files fit this limit. A single file larger than the limit stays.
  /// When null, the cache grows without a limit.
  final int? maxBytes;

  /// Name of the folder that stores the cached files.
  final String folderName;

  /// The maximum time to wait for the HTTP response.
  ///
  /// Only the future returned by [fetch] times out. The cache does not abort
  /// the underlying HTTP request when the timeout elapses.
  final Duration timeout;

  late final http.Client _client = _providedClient ?? http.Client();

  Future<void> _pruneTail = Future<void>.value();

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
  /// When the file is stale and the metadata holds an ETag or a Last-Modified
  /// value, the request carries the matching conditional header. A 304 keeps
  /// the file, refreshes its timestamp and reports `downloaded` as `false`.
  ///
  /// With [staleWhileRevalidate], the cache returns a stale file immediately
  /// and refreshes it in the background. The result carries a
  /// [DiskImageCacheResult.refresh] future that resolves to the refreshed
  /// result, or to the stale result when the refresh fails.
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
  /// 200 or 304.
  ///
  /// [onProgress] receives the downloaded fraction between `0.0` and `1.0`
  /// when the server reports the content length.
  Future<DiskImageCacheResult> fetch({
    required Uri url,
    required String cacheKey,
    Duration? maxAge,
    bool staleWhileRevalidate = false,
    void Function(double progress)? onProgress,
  }) async {
    _validateKey(cacheKey, 'cacheKey');
    final file = await _fileFor(cacheKey);
    final stat = await file.stat();
    final exists = stat.type != FileSystemEntityType.notFound;
    if (exists &&
        (maxAge == null ||
            DateTime.now().difference(stat.modified) <= maxAge)) {
      await _touch(cacheKey);
      return DiskImageCacheResult(
        file: file,
        downloaded: false,
        modified: stat.modified,
      );
    }
    if (exists && staleWhileRevalidate) {
      final stale = DiskImageCacheResult(
        file: file,
        downloaded: false,
        modified: stat.modified,
      );
      return DiskImageCacheResult(
        file: file,
        downloaded: false,
        modified: stat.modified,
        refresh: _refresh(
          url: url,
          destination: file,
          cacheKey: cacheKey,
          stale: stale,
          onProgress: onProgress,
        ),
      );
    }
    return _startDownload(
      url: url,
      destination: file,
      cacheKey: cacheKey,
      onProgress: onProgress,
    );
  }

  /// Downloads [url] and stores it under [cacheKey] without rendering it.
  Future<void> precache({
    required Uri url,
    required String cacheKey,
    Duration? maxAge,
  }) async {
    await fetch(url: url, cacheKey: cacheKey, maxAge: maxAge);
  }

  /// Pre-caches several images.
  ///
  /// It completes with the first error after all downloads finish. The cache
  /// keeps entries that download successfully.
  Future<void> precacheAll(
    Iterable<({Uri url, String cacheKey})> images, {
    Duration? maxAge,
  }) async {
    await Future.wait([
      for (final image in images)
        precache(url: image.url, cacheKey: image.cacheKey, maxAge: maxAge),
    ]);
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
    await _deleteMetadata(cacheKey);
  }

  /// Deletes cached files whose URL matches [pattern].
  ///
  /// A String pattern matches URLs that start with it. Any other pattern
  /// matches anywhere in the URL. The cache keeps entries without metadata.
  /// Returns the number of deleted files.
  Future<int> clearByPattern(Pattern pattern) async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || _isTempFile(entity)) continue;
      final segments = entity.uri.pathSegments;
      final cacheKey = segments.isEmpty ? entity.path : segments.last;
      final metadata = await _readMetadata(cacheKey);
      if (metadata == null) continue;
      final matches = pattern is String
          ? metadata.url.startsWith(pattern)
          : pattern.allMatches(metadata.url).isNotEmpty;
      if (!matches) continue;
      await entity.delete();
      await _deleteMetadata(cacheKey);
      removed++;
    }
    return removed;
  }

  /// Deletes the whole cache folder and every file in it.
  Future<void> clear() async {
    final directory = await _cacheDirectory();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  /// Deletes least-recently-used entries until the cache fits [maxBytes].
  ///
  /// The cache tracks the last access of every entry in its metadata. Entries
  /// without metadata fall back to their file modification time. Returns the
  /// number of deleted files. Does nothing when [maxBytes] is null.
  Future<int> prune() => _prune();

  Future<int> _prune({String? keep}) async {
    final limit = maxBytes;
    if (limit == null) {
      return 0;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) {
      return 0;
    }
    final entries = <({File file, String key, DateTime accessed})>[];
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || _isTempFile(entity)) {
        continue;
      }
      final segments = entity.uri.pathSegments;
      final key = segments.isEmpty ? entity.path : segments.last;
      final stat = await entity.stat();
      total += stat.size;
      final lastAccess = (await _readMetadata(key))?.lastAccess;
      entries.add((
        file: entity,
        key: key,
        accessed: DateTime.tryParse(lastAccess ?? '') ?? stat.modified,
      ));
    }
    if (total <= limit) {
      return 0;
    }
    entries.sort((a, b) => a.accessed.compareTo(b.accessed));
    var removed = 0;
    for (final entry in entries) {
      if (total <= limit) {
        break;
      }
      if (entry.key == keep) {
        continue;
      }
      final length = await entry.file.length();
      await entry.file.delete();
      await _deleteMetadata(entry.key);
      total -= length;
      removed++;
    }
    return removed;
  }

  Future<void> _pruneAfterDownload(String cacheKey) async {
    final next = _pruneTail.then((_) => _prune(keep: cacheKey));
    _pruneTail = next.then<void>((_) {}, onError: (Object _) {});
    try {
      await next;
    } catch (_) {
      // A failed prune must not fail the download.
    }
  }

  Future<void> _discardBody(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>();
    } catch (_) {
      // The response is being dropped; a failed drain changes nothing.
    }
  }

  String _nowIso() => _clock().toUtc().toIso8601String();

  Future<void> _touch(String cacheKey) async {
    final metadata = await _readMetadata(cacheKey);
    if (metadata == null) {
      return;
    }
    await _writeMetadata(cacheKey, metadata.withAccess(_nowIso()));
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

  Future<File> _metadataFileFor(String cacheKey) async {
    final directory = await _cacheDirectory();
    return File('${directory.path}/$_metadataFolderName/$cacheKey');
  }

  Future<_Metadata?> _readMetadata(String cacheKey) async {
    try {
      final file = await _metadataFileFor(cacheKey);
      if (!await file.exists()) return null;
      return _Metadata.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMetadata(String cacheKey, _Metadata metadata) async {
    final file = await _metadataFileFor(cacheKey);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(metadata.toJson()), flush: true);
  }

  Future<void> _deleteMetadata(String cacheKey) async {
    final file = await _metadataFileFor(cacheKey);
    if (await file.exists()) {
      await file.delete();
    }
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

  Future<DiskImageCacheResult> _startDownload({
    required Uri url,
    required File destination,
    required String cacheKey,
    void Function(double progress)? onProgress,
  }) {
    final path = destination.path;
    final inFlight = _inFlight[path];
    if (inFlight != null) return inFlight;
    final cancelled = Completer<void>();
    final tracked =
        _download(
              url: url,
              destination: destination,
              cacheKey: cacheKey,
              onProgress: onProgress,
              cancelled: cancelled,
            )
            .timeout(
              timeout,
              onTimeout: () {
                if (!cancelled.isCompleted) {
                  cancelled.complete();
                }
                throw TimeoutException('Request to $url timed out', timeout);
              },
            )
            .whenComplete(() {
              _inFlight.remove(path);
            });
    _inFlight[path] = tracked;
    return tracked;
  }

  Future<DiskImageCacheResult> _refresh({
    required Uri url,
    required File destination,
    required String cacheKey,
    required DiskImageCacheResult stale,
    void Function(double progress)? onProgress,
  }) async {
    try {
      return await _startDownload(
        url: url,
        destination: destination,
        cacheKey: cacheKey,
        onProgress: onProgress,
      );
    } catch (_) {
      return stale;
    }
  }

  Future<DiskImageCacheResult> _download({
    required Uri url,
    required File destination,
    required String cacheKey,
    void Function(double progress)? onProgress,
    required Completer<void> cancelled,
  }) async {
    final exists =
        (await destination.stat()).type != FileSystemEntityType.notFound;
    final previous = exists ? await _readMetadata(cacheKey) : null;
    final headers = <String, String>{};
    final etag = previous?.etag;
    if (etag != null) headers['If-None-Match'] = etag;
    final lastModified = previous?.lastModified;
    if (lastModified != null) headers['If-Modified-Since'] = lastModified;
    final request = http.Request('GET', url);
    if (headers.isNotEmpty) {
      request.headers.addAll(headers);
    }
    final response = await _client.send(request);
    if (response.statusCode == 304 && previous != null) {
      await _discardBody(response);
      await destination.setLastModified(_clock());
      await _touch(cacheKey);
      final stat = await destination.stat();
      return DiskImageCacheResult(
        file: destination,
        downloaded: false,
        modified: stat.modified,
      );
    }
    if (response.statusCode != 200) {
      await _discardBody(response);
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
      final sink = tempFile.openWrite();
      unawaited(sink.done.catchError((Object _, StackTrace _) {}));
      var received = 0;
      final progress = onProgress;
      final total = response.contentLength;
      final encoding = (response.headers['content-encoding'] ?? '')
          .toLowerCase();
      final expected =
          total != null &&
              total > 0 &&
              (encoding.isEmpty || encoding == 'identity')
          ? total
          : null;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (progress != null && expected != null) {
            progress((received / expected).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.close();
      }
      if (cancelled.isCompleted) {
        await tempFile.delete();
        throw TimeoutException('Request to $url was cancelled');
      }
      await _replace(tempFile, destination);
    } catch (_) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    }
    await _writeMetadata(
      cacheKey,
      _Metadata.fromResponse(url, response, _nowIso()),
    );
    final stat = await destination.stat();
    if (maxBytes != null) {
      await _pruneAfterDownload(cacheKey);
    }
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

const String _metadataFolderName = '.metadata';

class _Metadata {
  const _Metadata({
    required this.url,
    this.etag,
    this.lastModified,
    this.lastAccess,
  });

  final String url;
  final String? etag;
  final String? lastModified;
  final String? lastAccess;

  _Metadata withAccess(String lastAccess) {
    return _Metadata(
      url: url,
      etag: etag,
      lastModified: lastModified,
      lastAccess: lastAccess,
    );
  }

  static _Metadata fromResponse(
    Uri url,
    http.BaseResponse response,
    String lastAccess,
  ) {
    return _Metadata(
      url: url.toString(),
      etag: _headerValue(response.headers['etag']),
      lastModified: _headerValue(response.headers['last-modified']),
      lastAccess: lastAccess,
    );
  }

  static _Metadata? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    return _Metadata(
      url: url,
      etag: _headerValue(raw['etag'] as String?),
      lastModified: _headerValue(raw['lastModified'] as String?),
      lastAccess: _headerValue(raw['lastAccess'] as String?),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'url': url,
      if (etag != null) 'etag': etag,
      if (lastModified != null) 'lastModified': lastModified,
      if (lastAccess != null) 'lastAccess': lastAccess,
    };
  }

  static String? _headerValue(String? value) {
    return value == null || value.isEmpty ? null : value;
  }
}
