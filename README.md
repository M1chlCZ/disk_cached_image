# disk_cached_image

A Flutter widget and cache service that downloads a network image once and
serves it from disk on later builds and app launches.

## Features

- `DiskCachedImage` widget that renders a cached file
- `DiskImageCache` service with `fetch`, `evict`, `clear` and `size`
- TTL refresh through `maxAge`
- Atomic writes: the cache writes a temporary file, then renames it
- Single-flight downloads, so concurrent fetches for one key share a request
- Cache key validation against path traversal and Windows device names
- Gapless refresh: a stale image is replaced without a blank frame
- Optional byte limit with least-recently-used eviction
- Optional memory tier for recently decoded images
- Download progress through `onProgress`

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

The `cacheKey` names the file in the cache, and it's required. Share one
`DiskImageCache` between images so they reuse its HTTP client.

Fetch a file without the widget:

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

- The cache identifies files by `cacheKey` only, not by URL. When the URL
  changes, use a new key or call `evict`.
- A `null` `maxAge` keeps a file until you evict or clear it.
- `fetch` throws an `ArgumentError` for an invalid key, an `HttpException` for
  a non-200 response, and a `TimeoutException` when the cache timeout runs out
  (30 seconds by default).
- `DiskImageCache` takes a `client` and a `directoryProvider` for tests.

### Revalidation

The cache records the `ETag` and `Last-Modified` response headers in a JSON
sidecar under `.metadata/`. Once an entry is stale, the next request carries
`If-None-Match` or `If-Modified-Since` when those values exist. A `304`
response keeps the file, refreshes its timestamp and skips downloading the
bytes again.

### Stale-while-revalidate

Set `staleWhileRevalidate` on the widget to show the stale file right away and
refresh it in the background:

```dart
DiskCachedImage(
  url: 'https://picsum.photos/seed/one/200',
  cacheKey: 'coin-one',
  maxAge: const Duration(hours: 1),
  staleWhileRevalidate: true,
);
```

When the refresh finishes, the widget redraws with the new bytes. A failed
refresh leaves the stale image in place. The service exposes the same
behaviour through `result.refresh`.

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
anywhere in the URL. Entries without metadata stay put.

### Size limit

Set `maxBytes` to keep the cache directory bounded. After each download, the
cache deletes the least recently used files until the total fits. Each entry
keeps its access time in the metadata sidecar; files without metadata fall
back to their modification time.

```dart
final cache = DiskImageCache(maxBytes: 50 << 20); // 50 MiB
await cache.prune(); // enforces the limit now
```

One file larger than the limit stays in the cache.

### Memory tier

`MemoryImageCache` holds recently decoded image bytes in memory. Pass one
shared instance to the widgets to skip disk reads on rebuilds:

```dart
final memoryCache = MemoryImageCache(maxBytes: 16 << 20);

DiskCachedImage(
  url: 'https://picsum.photos/seed/one/200',
  cacheKey: 'coin-one',
  cache: cache,
  memoryCache: memoryCache,
);
```

The store drops the least recently used images when the byte limit would be
exceeded. `DiskCachedImage` renders from memory when the bytes are there and
fills the store after a load.

### Download progress

Pass `onProgress` to the cache or the widget to follow a download:

```dart
DiskCachedImage(
  url: 'https://picsum.photos/seed/one/200',
  cacheKey: 'coin-one',
  onProgress: (progress) => print('${(progress * 100).round()} %'),
);
```

Progress only arrives during a real download, and only when the server sends
the content length.

## Platforms

The package reads and writes files with `dart:io` and `path_provider`. It
supports Android, iOS, macOS, Windows and Linux. Web is not supported.

## Example

The [`example/`](example/) app renders two cached images and clears the cache.

## Licence

See [LICENSE](LICENSE).
