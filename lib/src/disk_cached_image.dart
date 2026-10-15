import 'package:flutter/material.dart';

import 'disk_image_cache.dart';

/// A widget that displays a network image from a [DiskImageCache].
///
/// The widget downloads the image once and serves it from disk on later
/// builds. When a download refreshes a rendered file, the widget decodes the
/// new bytes and shows them without a blank frame.
class DiskCachedImage extends StatefulWidget {
  /// Creates a [DiskCachedImage].
  const DiskCachedImage({
    super.key,
    required this.url,
    required this.cacheKey,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorBuilder,
    this.maxAge,
    this.staleWhileRevalidate = false,
    this.cache,
  });

  /// The URL to download the image from.
  final String url;

  /// The key that identifies the image inside the disk cache.
  final String cacheKey;

  /// The width of the rendered image.
  final double? width;

  /// The height of the rendered image.
  final double? height;

  /// How the widget inscribes the image into the available space.
  final BoxFit fit;

  /// The widget shown while the image loads from disk.
  final Widget? placeholder;

  /// The builder used when fetching or decoding the image fails.
  ///
  /// For decode failures, the widget passes it to [Image.errorBuilder]. For
  /// fetch failures, including a malformed [url], the widget calls it with the
  /// error and its stack trace. When it is `null`, fetch failures show a
  /// broken image icon. Decode failures render nothing in release builds. In
  /// debug builds Flutter renders its own error placeholder and logs the
  /// error.
  final ImageErrorWidgetBuilder? errorBuilder;

  /// The maximum age of a cached file before the cache downloads the file
  /// again.
  final Duration? maxAge;

  /// Whether the cache serves a stale file immediately and refreshes it in
  /// the background.
  ///
  /// The widget redraws with the refreshed bytes when the refresh finishes.
  /// It keeps the stale image when the refresh fails.
  final bool staleWhileRevalidate;

  /// The cache that fetches the image.
  ///
  /// Defaults to a new [DiskImageCache]. When the widget rebuilds with a
  /// different cache, including `null`, the widget fetches the image again
  /// with the new cache. Share one [DiskImageCache] instance across widgets so
  /// that its HTTP client can pool connections.
  final DiskImageCache? cache;

  @override
  State<DiskCachedImage> createState() => _DiskCachedImageState();
}

class _MtimeFileImage extends FileImage {
  const _MtimeFileImage(super.file, this.modified);

  final DateTime modified;

  @override
  bool operator ==(Object other) =>
      other is _MtimeFileImage && super == other && other.modified == modified;

  @override
  int get hashCode => Object.hash(super.hashCode, modified);

  @override
  String toString() =>
      '_MtimeFileImage("${file.path}", modified: $modified, '
      'scale: ${scale.toStringAsFixed(1)})';
}

class _DiskCachedImageState extends State<DiskCachedImage> {
  late DiskImageCache _cache;
  late Future<DiskImageCacheResult> _file;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _cache = widget.cache ?? DiskImageCache();
    _file = _load();
  }

  @override
  void didUpdateWidget(DiskCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cacheChanged = widget.cache != oldWidget.cache;
    if (cacheChanged) {
      _cache = widget.cache ?? DiskImageCache();
    }
    if (widget.url != oldWidget.url ||
        widget.cacheKey != oldWidget.cacheKey ||
        widget.maxAge != oldWidget.maxAge ||
        widget.staleWhileRevalidate != oldWidget.staleWhileRevalidate ||
        cacheChanged) {
      _file = _load();
    }
  }

  Future<DiskImageCacheResult> _load() {
    final Uri url;
    try {
      url = Uri.parse(widget.url);
    } on FormatException catch (error) {
      return Future.error(
        ArgumentError.value(widget.url, 'url', error.message),
      );
    }
    return _fetch(url);
  }

  Future<DiskImageCacheResult> _fetch(Uri url) {
    final generation = ++_generation;
    return _cache
        .fetch(
          url: url,
          cacheKey: widget.cacheKey,
          maxAge: widget.maxAge,
          staleWhileRevalidate: widget.staleWhileRevalidate,
        )
        .then((result) {
          final refresh = result.refresh;
          if (refresh != null) {
            refresh.then((refreshed) {
              if (!mounted || generation != _generation) return;
              setState(() {
                _file = Future.value(refreshed);
              });
            });
          }
          return result;
        });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DiskImageCacheResult>(
      future: _file,
      builder: (context, snapshot) {
        final result = snapshot.data;
        if (result != null) {
          return Image(
            image: _MtimeFileImage(result.file, result.modified),
            gaplessPlayback: true,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: widget.errorBuilder,
          );
        }
        if (snapshot.hasError) {
          return _buildError(context, snapshot.error!, snapshot.stackTrace);
        }
        return widget.placeholder ?? const SizedBox.shrink();
      },
    );
  }

  Widget _buildError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    final errorBuilder = widget.errorBuilder;
    if (errorBuilder != null) {
      return errorBuilder(context, error, stackTrace);
    }
    final icon = Icon(Icons.broken_image);
    if (widget.width == null && widget.height == null) {
      return icon;
    }
    return SizedBox(width: widget.width, height: widget.height, child: icon);
  }
}
