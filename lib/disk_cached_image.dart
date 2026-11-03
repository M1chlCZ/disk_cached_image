/// A Flutter widget and cache service that downloads network images to disk
/// once, serves them from disk, and supports TTL, eviction, clearing, a size
/// limit, and an optional memory tier.
library;

export 'src/disk_cached_image.dart';
export 'src/disk_image_cache.dart';
export 'src/memory_image_cache.dart';
