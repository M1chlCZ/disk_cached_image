## 0.2.0

- HTTP revalidation: the cache stores ETag and Last-Modified values and sends
  conditional requests. A 304 keeps the file and refreshes its timestamp.
- `staleWhileRevalidate`: a stale file is served immediately while the refresh
  runs in the background. The result carries a `refresh` future.
- `precache` and `precacheAll` warm the cache without rendering.
- `clearByPattern` removes entries by URL prefix (String) or match (RegExp).
- Entries now keep a JSON metadata sidecar under `.metadata/`.

## 0.1.2

- Documentation and internal cleanup.

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
