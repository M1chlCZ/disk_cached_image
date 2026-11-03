import 'dart:collection';
import 'dart:typed_data';

/// A small least-recently-used store of image bytes.
///
/// The store keeps the most recently used images in memory and drops the
/// oldest entries when [maxBytes] would be exceeded. Pass it to
/// [DiskCachedImage] to skip disk reads and decodes on rebuilds.
class MemoryImageCache {
  /// Creates a memory cache with a byte limit.
  MemoryImageCache({this.maxBytes = 8 << 20});

  /// The maximum number of bytes kept in memory.
  final int maxBytes;

  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();
  var _size = 0;

  /// The number of stored images.
  int get length => _entries.length;

  /// The total size of the stored images in bytes.
  int get size => _size;

  /// Returns the bytes stored under [key] and marks them as recently used.
  Uint8List? get(String key) {
    final Uint8List? bytes = _entries.remove(key);
    if (bytes == null) {
      return null;
    }
    _entries[key] = bytes;
    return bytes;
  }

  /// Stores [bytes] under [key], dropping the oldest entries when needed.
  ///
  /// An image larger than [maxBytes] is not stored. Empty bytes are ignored.
  void put(String key, Uint8List bytes) {
    final Uint8List? previous = _entries.remove(key);
    if (previous != null) {
      _size -= previous.length;
    }
    if (bytes.isEmpty || bytes.length > maxBytes) {
      return;
    }
    _entries[key] = bytes;
    _size += bytes.length;
    while (_size > maxBytes && _entries.isNotEmpty) {
      final String oldest = _entries.keys.first;
      final Uint8List dropped = _entries.remove(oldest)!;
      _size -= dropped.length;
    }
  }

  /// Drops the entry stored under [key].
  void remove(String key) {
    final Uint8List? dropped = _entries.remove(key);
    if (dropped != null) {
      _size -= dropped.length;
    }
  }

  /// Drops every entry.
  void clear() {
    _entries.clear();
    _size = 0;
  }
}
