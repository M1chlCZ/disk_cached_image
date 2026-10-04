import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A disk-backed cache for network images.
///
/// Files are stored in a dedicated folder and named by the `cacheKey` passed
/// to [fetch]. A cached file is reused until it is removed with [evict] or
/// [clear], or until it is older than the `maxAge` given to [fetch].
class DiskImageCache {
  /// Creates a [DiskImageCache].
  ///
  /// The [client] is used to download images. When it is omitted, a new
  /// [http.Client] is created for each download and closed afterwards.
  ///
  /// The [directoryProvider] returns the base directory that contains the
  /// cache folder. It defaults to [getApplicationDocumentsDirectory].
  ///
  /// The [folderName] is the name of the cache folder inside the base
  /// directory.
  DiskImageCache({
    http.Client? client,
    Future<Directory> Function()? directoryProvider,
    this.folderName = 'disk_cached_image',
  }) : _client = client,
       _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory;

  final http.Client? _client;
  final Future<Directory> Function() _directoryProvider;

  /// Name of the folder that stores the cached files.
  final String folderName;

  /// Downloads [url] and stores it on disk under [cacheKey].
  ///
  /// Returns the cached file. A download only happens when no file exists for
  /// [cacheKey], or when the existing file is older than [maxAge]. With a
  /// `null` [maxAge] the file is kept until it is evicted.
  ///
  /// Throws an [ArgumentError] when [cacheKey] is empty or contains path
  /// separators or relative path segments. Throws an [HttpException] when the
  /// server responds with a status code other than 200.
  Future<File> fetch({
    required Uri url,
    required String cacheKey,
    Duration? maxAge,
  }) async {
    _validateCacheKey(cacheKey);
    final file = await _fileFor(cacheKey);
    if (await file.exists()) {
      if (maxAge == null) return file;
      final age = DateTime.now().difference(await file.lastModified());
      if (age <= maxAge) return file;
    }
    return _download(url: url, destination: file);
  }

  /// Deletes the cached file stored under [cacheKey].
  ///
  /// Does nothing when no file exists for [cacheKey]. Throws an
  /// [ArgumentError] when [cacheKey] is invalid.
  Future<void> evict(String cacheKey) async {
    _validateCacheKey(cacheKey);
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
  /// Returns `0` when the cache folder does not exist.
  Future<int> size() async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
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

  static void _validateCacheKey(String cacheKey) {
    if (cacheKey.isEmpty ||
        cacheKey.contains('/') ||
        cacheKey.contains(r'\') ||
        cacheKey.contains('..') ||
        cacheKey.startsWith('.')) {
      throw ArgumentError.value(
        cacheKey,
        'cacheKey',
        'must not be empty or contain path separators or relative segments',
      );
    }
  }

  Future<File> _download({required Uri url, required File destination}) async {
    final client = _client ?? http.Client();
    try {
      final response = await client.get(url);
      if (response.statusCode != 200) {
        throw HttpException(
          'Request to $url failed with status ${response.statusCode}.',
          uri: url,
        );
      }
      await destination.parent.create(recursive: true);
      final tempFile = File('${destination.path}.tmp');
      try {
        await tempFile.writeAsBytes(response.bodyBytes, flush: true);
        await _replace(tempFile, destination);
      } catch (_) {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        rethrow;
      }
      return destination;
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }

  static Future<void> _replace(File source, File destination) async {
    try {
      await source.rename(destination.path);
    } on FileSystemException {
      if (!await destination.exists()) rethrow;
      await destination.delete();
      await source.rename(destination.path);
    }
  }
}
