# disk_cached_image

A Flutter widget and cache service that downloads network images to disk once,
serves them from disk on later builds and app launches, and supports TTL,
eviction, and clearing.

## Features

- **Disk persistence** — images are stored as files so they survive app
  restarts and are not downloaded again.
- **TTL** — pass `maxAge` to `DiskCachedImage` or `DiskImageCache.fetch` to
  re-download a file that is older than the given duration.
- **Eviction** — remove one entry with `DiskImageCache.evict`, or the whole
  cache folder with `DiskImageCache.clear`.
- **Atomic writes** — a download is first written to a temporary file and then
  renamed into place, so an interrupted download never leaves a corrupt entry.
- **Single-flight downloads** — concurrent fetches for the same cache key share
  one HTTP request and receive the same result.
- **Key validation** — cache keys are rejected when they could escape the cache
  folder or clash with Windows reserved device names.
- **Cache size** — `DiskImageCache.size` returns the total number of bytes
  stored on disk.
- **Gapless refresh** — when a stale file is replaced, the new bitmap is shown
  without a blank frame in between.

## Platforms

The package uses `dart:io` and `path_provider` to read and write files, so it
supports Android, iOS, macOS, Windows, and Linux. Web is not supported.

## Installation

The package is not published on pub.dev yet. Add it to your `pubspec.yaml`
from this repository with a path dependency:

```yaml
dependencies:
  disk_cached_image:
    path: packages/disk_cached_image
```

You can also depend on the Git repository directly and point at the package
folder.

## Usage

### The `DiskCachedImage` widget

`DiskCachedImage` downloads the image once and renders it from disk on every
later build:

```dart
import 'package:disk_cached_image/disk_cached_image.dart';
import 'package:flutter/material.dart';

class CoinAvatar extends StatelessWidget {
  const CoinAvatar({super.key});

  @override
  Widget build(BuildContext context) {
    return const DiskCachedImage(
      url: 'https://picsum.photos/seed/one/200',
      cacheKey: 'coin-one',
      width: 64,
      height: 64,
      maxAge: Duration(days: 7),
      placeholder: Center(child: CircularProgressIndicator()),
      errorBuilder: _buildError,
    );
  }

  static Widget _buildError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return const Icon(Icons.broken_image, size: 64);
  }
}
```

`cacheKey` is required and identifies the file in the cache. Reuse one
`DiskImageCache` through the `cache` parameter to share the underlying HTTP
client between many images:

```dart
final cache = DiskImageCache();

DiskCachedImage(
  url: 'https://picsum.photos/seed/two/200',
  cacheKey: 'coin-two',
  cache: cache,
)
```

The widget shows `placeholder` while the file is being fetched. `errorBuilder`
is used for fetch errors; when it is omitted, a broken image icon is shown. It
is also passed to `Image.errorBuilder` for decode failures; when it is omitted
there, decode failures render nothing in release builds, while in debug builds
Flutter renders its own error placeholder and logs the decode error.

### The `DiskImageCache` API

```dart
import 'package:disk_cached_image/disk_cached_image.dart';

final cache = DiskImageCache();

// Fetch a file, downloading it when it is missing or older than maxAge.
final DiskImageCacheResult result = await cache.fetch(
  url: Uri.parse('https://picsum.photos/seed/one/200'),
  cacheKey: 'coin-one',
  maxAge: const Duration(days: 7),
);
print(result.file.path); // path of the cached file
print(result.modified); // modification time used to detect refreshes
// true when this call downloaded the file (or joined an in-flight download)
print(result.downloaded);

// Remove a single entry.
await cache.evict('coin-one');

// Total bytes stored in the cache.
final int bytes = await cache.size();

// Remove every cached file.
await cache.clear();
```

Notes:

- The cache is keyed by `cacheKey` only, not by URL. If the URL behind a key
  changes, call `evict` or use a new key.
- A `null` `maxAge` keeps a file until it is evicted or cleared.
- `fetch` throws an `ArgumentError` for an invalid key, an `HttpException` for
  a non-200 response, and a `TimeoutException` when the request exceeds the
  cache `timeout` (30 seconds by default).
- `DiskImageCache` takes an optional `client` and `directoryProvider`, which is
  useful for tests.

## License

See [LICENSE](LICENSE).
