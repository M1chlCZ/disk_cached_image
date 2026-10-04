import 'dart:io';

import 'package:flutter/material.dart';

import 'disk_image_cache.dart';

/// A widget that displays a network image from a [DiskImageCache].
///
/// The image is downloaded once and served from disk on later builds.
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

  /// The builder used when the downloaded file cannot be decoded as an image.
  final ImageErrorWidgetBuilder? errorBuilder;

  /// The maximum age of a cached file before it is downloaded again.
  final Duration? maxAge;

  /// The cache used to fetch the image. Defaults to a new [DiskImageCache].
  final DiskImageCache? cache;

  @override
  State<DiskCachedImage> createState() => _DiskCachedImageState();
}

class _DiskCachedImageState extends State<DiskCachedImage> {
  late DiskImageCache _cache;
  late Future<File> _file;

  @override
  void initState() {
    super.initState();
    _cache = widget.cache ?? DiskImageCache();
    _file = _load();
  }

  @override
  void didUpdateWidget(DiskCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cache != oldWidget.cache) {
      _cache = widget.cache ?? _cache;
    }
    if (widget.url != oldWidget.url ||
        widget.cacheKey != oldWidget.cacheKey ||
        widget.cache != oldWidget.cache) {
      _file = _load();
    }
  }

  Future<File> _load() => _cache.fetch(
    url: Uri.parse(widget.url),
    cacheKey: widget.cacheKey,
    maxAge: widget.maxAge,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _file,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null) {
          return Image.file(
            file,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: widget.errorBuilder,
          );
        }
        if (snapshot.hasError) {
          return _buildError();
        }
        return widget.placeholder ?? const SizedBox.shrink();
      },
    );
  }

  Widget _buildError() {
    final icon = Icon(Icons.broken_image);
    if (widget.width == null && widget.height == null) {
      return icon;
    }
    return SizedBox(width: widget.width, height: widget.height, child: icon);
  }
}
