## 0.1.1

- Rewrite the README. The install section now uses
  `flutter pub add disk_cached_image`.

## 0.1.0

- Initial release.
- `DiskCachedImage` widget that downloads a network image to disk once and
  renders it from disk on later builds.
- `DiskImageCache` service with `fetch`, `evict`, `clear`, and `size`.
- TTL support through the `maxAge` parameter.
- Atomic writes through temporary files and rename.
- Single-flight downloads: concurrent fetches for one cache key share a single
  HTTP request.
- Cache key validation against path traversal and Windows reserved device
  names.
- Gapless refresh when a stale file is replaced.
