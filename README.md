# disk_cached_image

A Flutter widget and cache service that downloads network images to disk once
and serves them from disk on later builds and app launches.

## Features

- `DiskCachedImage` widget that renders a cached file
- `DiskImageCache` service with `fetch`, `evict`, `clear`, and `size`
- TTL refresh with `maxAge`
- Atomic writes through a temporary file and a rename
- Single-flight downloads: concurrent fetches for one key share one request
- Cache key validation against path traversal and Windows device names
- Gapless refresh: a stale image is replaced without a blank frame

## Install

```bash
flutter pub add disk_cached_image
```

## Usage

```dart
final cache = DiskImageCache();

DiskCachedImage(
  url: 'https://picsum.photos/seed/one/200',
  cacheKey: 'coin-one',
  width: 64,
  height: 64,
  maxAge: const Duration(days: 7),
  cache: cache,
  placeholder: const Center(child: CircularProgressIndicator()),
  errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
);
```

The `cacheKey` identifies the file in the cache and is required. Share one
`DiskImageCache` between images to reuse its HTTP client.

Fetch files without the widget:

```dart
final DiskImageCacheResult result = await cache.fetch(
  url: Uri.parse('https://picsum.photos/seed/one/200'),
  cacheKey: 'coin-one',
  maxAge: const Duration(days: 7),
);

print(result.file.path); // path of the cached file
print(result.downloaded); // true when this call downloaded the file

await cache.evict('coin-one');
final int bytes = await cache.size();
await cache.clear();
```

Notes:

- The cache uses `cacheKey` only, not the URL. Use a new key or call `evict`
  when the URL changes.
- A `null` `maxAge` keeps a file until eviction or clearing.
- `fetch` throws an `ArgumentError` for an invalid key, an `HttpException` for
  a non-200 response, and a `TimeoutException` after the cache timeout (30
  seconds by default).
- `DiskImageCache` accepts a `client` and a `directoryProvider` for tests.

### Revalidation

The cache stores the `ETag` and `Last-Modified` response headers in a JSON
sidecar under `.metadata/`. When a stale entry has a stored value, the next
request carries `If-None-Match` or `If-Modified-Since`. A `304` response keeps
the file and refreshes its timestamp, so the cache does not download the bytes
again.

### Stale-while-revalidate

Set `staleWhileRevalidate` on the widget to show a stale file at once and
refresh it in the background:

```dart
DiskCachedImage(
  url: 'https://picsum.photos/seed/one/200',
  cacheKey: 'coin-one',
  maxAge: const Duration(hours: 1),
  staleWhileRevalidate: true,
);
```

The widget redraws with the refreshed bytes when the refresh finishes. A failed
refresh keeps the stale image. The service reports the same behavior through
`result.refresh`.

### Precache

```dart
await cache.precache(
  url: Uri.parse('https://picsum.photos/seed/one/200'),
  cacheKey: 'coin-one',
);

await cache.precacheAll([
  (url: Uri.parse('https://picsum.photos/seed/two/200'), cacheKey: 'coin-two'),
  (url: Uri.parse('https://picsum.photos/seed/three/200'), cacheKey: 'coin-three'),
]);
```

### Clear by pattern

```dart
final int removed = await cache.clearByPattern('https://picsum.photos/seed/');
final int matched = await cache.clearByPattern(RegExp(r'picsum\.photos'));
```

A String pattern matches URLs that start with it. Any other pattern matches
anywhere in the URL. Entries without metadata are kept.

## Platforms

The package reads and writes files with `dart:io` and `path_provider`. It
supports Android, iOS, macOS, Windows, and Linux. Web is not supported.

## Example

The [`example/`](example/) app renders two cached images and clears the cache.

## License

See [LICENSE](LICENSE).
