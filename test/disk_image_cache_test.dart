import 'dart:io';

import 'package:disk_cached_image/disk_cached_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('disk_cached_image_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  DiskImageCache cacheWith(MockClient client) =>
      DiskImageCache(client: client, directoryProvider: () async => tempDir);

  test('downloads once and serves subsequent reads from disk', () async {
    var requests = 0;
    final cache = cacheWith(
      MockClient((request) async {
        requests++;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    final url = Uri.parse('https://example.com/a.png');

    final first = await cache.fetch(url: url, cacheKey: 'a');
    final second = await cache.fetch(url: url, cacheKey: 'a');

    expect(requests, 1);
    expect(first.path, second.path);
    expect(await first.readAsBytes(), [1, 2, 3]);
  });

  test('refetches when maxAge has expired', () async {
    var requests = 0;
    final cache = cacheWith(
      MockClient((request) async {
        requests++;
        return http.Response.bytes([requests], 200);
      }),
    );
    final url = Uri.parse('https://example.com/a.png');
    const maxAge = Duration(milliseconds: 1);

    await cache.fetch(url: url, cacheKey: 'a', maxAge: maxAge);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await cache.fetch(url: url, cacheKey: 'a', maxAge: maxAge);

    expect(requests, 2);
  });

  test('throws HttpException on non-200 without writing a file', () async {
    final cache = cacheWith(
      MockClient((request) async => http.Response('nope', 404)),
    );
    final url = Uri.parse('https://example.com/missing.png');

    await expectLater(
      cache.fetch(url: url, cacheKey: 'missing'),
      throwsA(isA<HttpException>()),
    );
    expect(
      File('${tempDir.path}/disk_cached_image/missing').existsSync(),
      isFalse,
    );
  });

  test(
    'evict removes a single entry, clear removes all, size counts bytes',
    () async {
      final cache = cacheWith(
        MockClient((request) async {
          if (request.url.path.contains('a')) {
            return http.Response.bytes([1, 2, 3, 4], 200);
          }
          return http.Response.bytes([5, 6], 200);
        }),
      );

      await cache.fetch(
        url: Uri.parse('https://example.com/a.png'),
        cacheKey: 'a',
      );
      await cache.fetch(
        url: Uri.parse('https://example.com/b.png'),
        cacheKey: 'b',
      );

      expect(await cache.size(), 6);
      await cache.evict('a');
      expect(await cache.size(), 2);
      await cache.clear();
      expect(await cache.size(), 0);
    },
  );

  test('rejects cache keys containing path separators', () async {
    final cache = cacheWith(
      MockClient((request) async => http.Response.bytes([1], 200)),
    );

    await expectLater(
      cache.fetch(
        url: Uri.parse('https://example.com/a.png'),
        cacheKey: '../evil',
      ),
      throwsArgumentError,
    );
  });
}
