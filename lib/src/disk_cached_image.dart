import 'package:flutter/material.dart';

import 'disk_image_cache.dart';

/// A widget that displays a network image from a [DiskImageCache].
///
/// The image is downloaded once and served from disk on later builds. When a
/// download refreshes a file that was rendered before, the stale bitmap is
/// evicted from Flutter's in-memory image cache and the file is decoded
/// again.
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
    this.cache,
  });

  /// The URL the image is downloaded from.
  final String url;

  /// The key that identifies the image inside the disk cache.
  final String cacheKey;

  /// The width of the rendered image.
  final double? width;

  /// The height of the rendered image.
  final double? height;

  /// How the image should be inscribed into the available space.
  final BoxFit fit;

  /// The widget shown while the image is being fetched from disk.
  final Widget? placeholder;

  /// The builder used when fetching or decoding the image fails.
  ///
  /// For decode failures it is passed to [Image.errorBuilder]. For fetch
  /// failures (including a malformed [url]) it is invoked directly with the
  /// error and its stack trace. When `null`, a broken image icon is shown
  /// instead.
  final ImageErrorWidgetBuilder? errorBuilder;

  /// The maximum age of a cached file before it is downloaded again.
  final Duration? maxAge;

  /// The cache used to fetch the image.
  ///
  /// Defaults to a new [DiskImageCache]. When the widget is rebuilt with a
  /// different cache, including `null`, the image is refetched with the new
  /// cache and its bitmaps are evicted from Flutter's in-memory image cache.
  /// Reuse one [DiskImageCache] instance across widgets so that its HTTP
  /// client can pool connections.
  final DiskImageCache? cache;

  @override
  State<DiskCachedImage> createState() => _DiskCachedImageState();
}

class _DiskCachedImageState extends State<DiskCachedImage> {
  late DiskImageCache _cache;
  late Future<DiskImageCacheResult> _file;
  int _generation = 0;

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

  Future<DiskImageCacheResult> _fetch(Uri url) async {
    final result = await _cache.fetch(
      url: url,
      cacheKey: widget.cacheKey,
      maxAge: widget.maxAge,
    );
    if (result.downloaded) {
      PaintingBinding.instance.imageCache.evict(FileImage(result.file));
      _generation++;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DiskImageCacheResult>(
      future: _file,
      builder: (context, snapshot) {
        final result = snapshot.data;
        if (result != null) {
          return Image.file(
            result.file,
            key: ValueKey<int>(_generation),
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
