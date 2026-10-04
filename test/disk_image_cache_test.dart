import 'dart:async';
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
    expect(first.downloaded, isTrue);
    expect(second.downloaded, isFalse);
    expect(first.file.path, second.file.path);
    expect(second.modified, first.modified);
    expect(await first.file.readAsBytes(), [1, 2, 3]);
  });

  test('overlapping fetches for the same key share one download', () async {
    var requests = 0;
    final firstRequest = Completer<void>();
    final release = Completer<void>();
    final cache = cacheWith(
      MockClient((request) async {
        requests++;
        if (!firstRequest.isCompleted) firstRequest.complete();
        await release.future;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    final url = Uri.parse('https://example.com/a.png');

    final first = cache.fetch(url: url, cacheKey: 'a');
    await firstRequest.future;
    expect(requests, 1);

    final second = cache.fetch(url: url, cacheKey: 'a');
    var secondCompleted = false;
    unawaited(second.then((_) => secondCompleted = true));

    // Drain the event queue while the only HTTP request is blocked. If the
    // second fetch did not join the in-flight download, it issues its own
    // request during this drain and `requests` becomes 2.
    await pumpEventQueue();
    expect(requests, 1);
    expect(secondCompleted, isFalse);

    release.complete();
    final results = await Future.wait([first, second]);

    expect(requests, 1);
    expect(results[0].downloaded, isTrue);
    expect(results[1].downloaded, isTrue);
    expect(results[0].file.path, results[1].file.path);
    expect(results[0].modified, results[1].modified);
    expect(results[0].file.existsSync(), isTrue);
    expect(await results[0].file.readAsBytes(), [1, 2, 3]);
    expect(await results[1].file.readAsBytes(), [1, 2, 3]);
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
    const maxAge = Duration(minutes: 1);

    final first = await cache.fetch(url: url, cacheKey: 'a', maxAge: maxAge);
    await first.file.setLastModified(
      DateTime.now().subtract(const Duration(minutes: 5)),
    );
    final second = await cache.fetch(url: url, cacheKey: 'a', maxAge: maxAge);

    expect(requests, 2);
    expect(first.downloaded, isTrue);
    expect(second.downloaded, isTrue);
    expect(second.modified.isBefore(first.modified), isFalse);
    expect(await second.file.readAsBytes(), [2]);
  });

  test('aborts the download after the configured timeout', () async {
    final cache = DiskImageCache(
      client: MockClient((request) => Completer<http.Response>().future),
      directoryProvider: () async => tempDir,
      timeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      cache.fetch(url: Uri.parse('https://example.com/a.png'), cacheKey: 'a'),
      throwsA(isA<TimeoutException>()),
    );
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

  test('size ignores orphaned temp files and clear removes them', () async {
    final cache = cacheWith(
      MockClient((request) async => http.Response.bytes([1], 200)),
    );
    final directory = Directory('${tempDir.path}/disk_cached_image');
    await directory.create(recursive: true);
    await File('${directory.path}/real').writeAsBytes([1, 2, 3]);
    await File('${directory.path}/photo.tmp').writeAsBytes([4, 5]);
    await File('${directory.path}/real.tmp-1-2').writeAsBytes([6, 7, 8, 9]);

    expect(await cache.size(), 5);
    await cache.clear();
    expect(await directory.exists(), isFalse);
  });

  test('rejects invalid cache keys', () async {
    final cache = cacheWith(
      MockClient((request) async => http.Response.bytes([1], 200)),
    );
    final url = Uri.parse('https://example.com/a.png');
    final keys = <String>[
      '',
      'a/b',
      r'a\b',
      '..',
      '.hidden',
      'NUL',
      'nul.txt',
      'CON',
      'LPT9',
      'key.',
      'a' * 129,
    ];

    for (final key in keys) {
      await expectLater(
        cache.fetch(url: url, cacheKey: key),
        throwsArgumentError,
        reason: 'key "$key" must be rejected',
      );
    }
  });

  test('rejects invalid folder names', () {
    final names = <String>['', 'a/b', r'a\b', '..', '.hidden', 'NUL'];

    for (final name in names) {
      expect(
        () => DiskImageCache(
          folderName: name,
          directoryProvider: () async => tempDir,
        ),
        throwsArgumentError,
        reason: 'folder "$name" must be rejected',
      );
    }
  });
}
