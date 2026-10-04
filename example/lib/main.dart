import 'package:disk_cached_image/disk_cached_image.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'disk_cached_image example',
      home: ExamplePage(),
    );
  }
}

class ExamplePage extends StatelessWidget {
  const ExamplePage({super.key});

  Future<void> _clearCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final cache = DiskImageCache();
    final before = await cache.size();
    await cache.clear();
    final after = await cache.size();
    messenger.showSnackBar(
      SnackBar(content: Text('Cache size: $before -> $after bytes')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('disk_cached_image example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Wrap(
              spacing: 16,
              children: [
                DiskCachedImage(
                  url: 'https://picsum.photos/seed/one/200',
                  cacheKey: 'picsum-one',
                  width: 120,
                  height: 120,
                ),
                DiskCachedImage(
                  url: 'https://picsum.photos/seed/two/200',
                  cacheKey: 'picsum-two',
                  width: 120,
                  height: 120,
                  placeholder: Center(child: CircularProgressIndicator()),
                  errorBuilder: _buildError,
                ),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => _clearCache(context),
              child: const Text('Clear cache'),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _buildError(BuildContext context, Object error, StackTrace? stackTrace) {
  return const Icon(Icons.broken_image, size: 120);
}
