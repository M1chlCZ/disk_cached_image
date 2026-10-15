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

  test('revalidates with ETag and keeps the file on 304', () async {
    var requests = 0;
    final conditional = <String?>[];
    final cache = cacheWith(
      MockClient((request) async {
        requests++;
        conditional.add(request.headers['If-None-Match']);
        if (requests == 1) {
          return http.Response.bytes([1, 2, 3], 200, headers: {'etag': '"v1"'});
        }
        return http.Response('', 304);
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
    expect(conditional, [null, '"v1"']);
    expect(second.downloaded, isFalse);
    expect(await second.file.readAsBytes(), [1, 2, 3]);
    expect(second.modified.isAfter(first.modified), isTrue);
  });

  test('revalidates with Last-Modified and replaces the file on 200', () async {
    var requests = 0;
    final conditional = <String?>[];
    final cache = cacheWith(
      MockClient((request) async {
        requests++;
        conditional.add(request.headers['If-Modified-Since']);
        if (requests == 1) {
          return http.Response.bytes(
            [1],
            200,
            headers: {'last-modified': 'Mon, 01 Jan 2024 00:00:00 GMT'},
          );
        }
        return http.Response.bytes([2], 200);
      }),
    );
    final url = Uri.parse('https://example.com/b.png');
    const maxAge = Duration(minutes: 1);

    final first = await cache.fetch(url: url, cacheKey: 'b', maxAge: maxAge);
    await first.file.setLastModified(
      DateTime.now().subtract(const Duration(minutes: 5)),
    );
    final second = await cache.fetch(url: url, cacheKey: 'b', maxAge: maxAge);

    expect(requests, 2);
    expect(conditional, [null, 'Mon, 01 Jan 2024 00:00:00 GMT']);
    expect(second.downloaded, isTrue);
    expect(await second.file.readAsBytes(), [2]);
  });

  test(
    'serves a stale file immediately and refreshes in the background',
    () async {
      var requests = 0;
      final cache = cacheWith(
        MockClient((request) async {
          requests++;
          return http.Response.bytes([requests], 200);
        }),
      );
      final url = Uri.parse('https://example.com/c.png');
      const maxAge = Duration(minutes: 1);

      final first = await cache.fetch(url: url, cacheKey: 'c', maxAge: maxAge);
      expect(first.downloaded, isTrue);
      await first.file.setLastModified(
        DateTime.now().subtract(const Duration(minutes: 5)),
      );

      final stale = await cache.fetch(
        url: url,
        cacheKey: 'c',
        maxAge: maxAge,
        staleWhileRevalidate: true,
      );
      expect(stale.downloaded, isFalse);
      expect(await stale.file.readAsBytes(), [1]);
      final refresh = stale.refresh;
      expect(refresh, isNotNull);

      final refreshed = await refresh!;
      expect(refreshed.downloaded, isTrue);
      expect(requests, 2);
      expect(await refreshed.file.readAsBytes(), [2]);
    },
  );

  test('a failed background refresh keeps the stale result', () async {
    var requests = 0;
    final cache = cacheWith(
      MockClient((request) async {
        requests++;
        if (requests == 1) return http.Response.bytes([1], 200);
        return http.Response('nope', 500);
      }),
    );
    final url = Uri.parse('https://example.com/d.png');
    const maxAge = Duration(minutes: 1);

    await cache.fetch(url: url, cacheKey: 'd', maxAge: maxAge);
    await File(
      '${tempDir.path}/disk_cached_image/d',
    ).setLastModified(DateTime.now().subtract(const Duration(minutes: 5)));

    final stale = await cache.fetch(
      url: url,
      cacheKey: 'd',
      maxAge: maxAge,
      staleWhileRevalidate: true,
    );
    final refresh = await stale.refresh!;

    expect(requests, 2);
    expect(refresh.downloaded, isFalse);
    expect(await refresh.file.readAsBytes(), [1]);
  });

  test('precache and precacheAll populate the cache', () async {
    var requests = 0;
    final cache = cacheWith(
      MockClient((request) async {
        requests++;
        return http.Response.bytes([requests], 200);
      }),
    );

    await cache.precache(
      url: Uri.parse('https://example.com/p1.png'),
      cacheKey: 'p1',
    );
    await cache.precacheAll([
      (url: Uri.parse('https://example.com/p2.png'), cacheKey: 'p2'),
      (url: Uri.parse('https://example.com/p3.png'), cacheKey: 'p3'),
    ]);

    expect(requests, 3);
    for (final key in ['p1', 'p2', 'p3']) {
      final hit = await cache.fetch(
        url: Uri.parse('https://example.com/$key.png'),
        cacheKey: key,
      );
      expect(hit.downloaded, isFalse, reason: key);
    }
  });

  test('clearByPattern removes matching entries only', () async {
    final cache = cacheWith(
      MockClient((request) async => http.Response.bytes([1], 200)),
    );
    await cache.fetch(
      url: Uri.parse('https://example.com/a.png'),
      cacheKey: 'a',
    );
    await cache.fetch(url: Uri.parse('https://other.com/b.png'), cacheKey: 'b');
    await cache.fetch(
      url: Uri.parse('https://cdn.example.net/c.png'),
      cacheKey: 'c',
    );
    final stray = File('${tempDir.path}/disk_cached_image/stray');
    await stray.writeAsBytes([9]);

    expect(await cache.clearByPattern('https://example.com/'), 1);
    expect(File('${tempDir.path}/disk_cached_image/a').existsSync(), isFalse);
    expect(File('${tempDir.path}/disk_cached_image/b').existsSync(), isTrue);

    expect(await cache.clearByPattern(RegExp(r'example\.net')), 1);
    expect(File('${tempDir.path}/disk_cached_image/c').existsSync(), isFalse);
    expect(stray.existsSync(), isTrue);
    expect(await cache.clearByPattern(RegExp('.')), 1);
    expect(await cache.clearByPattern(RegExp('.')), 0);
  });
}
