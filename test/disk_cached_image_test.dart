import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:disk_cached_image/disk_cached_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final List<int> _pixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Future<List<int>> _solidPng(ui.Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint()..color = color);
  final image = await recorder.endRecording().toImage(2, 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump();
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition was not met');
}

Future<void> _pumpUntilImage(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump();
    await Future<void>.delayed(Duration.zero);
    if (find.byType(RawImage).evaluate().isEmpty) continue;
    final renderImage = tester.renderObject<RenderImage>(find.byType(RawImage));
    if (renderImage.image != null) return;
  }
  fail('image was not decoded');
}

Future<ui.Color> _renderedPixel(WidgetTester tester) async {
  final renderImage = tester.renderObject<RenderImage>(find.byType(RawImage));
  final image = renderImage.image!;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  return ui.Color.fromARGB(bytes[3], bytes[0], bytes[1], bytes[2]);
}

Future<void> _pumpUntilPixel(WidgetTester tester, ui.Color color) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump();
    await Future<void>.delayed(Duration.zero);
    if (find.byType(RawImage).evaluate().isEmpty) continue;
    final renderImage = tester.renderObject<RenderImage>(find.byType(RawImage));
    final image = renderImage.image;
    if (image == null) continue;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    if (ui.Color.fromARGB(bytes[3], bytes[0], bytes[1], bytes[2]) == color) {
      return;
    }
  }
  fail('pixel $color was not rendered');
}

void main() {
  testWidgets('renders the downloaded image', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'disk_cached_image_widget',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final cache = DiskImageCache(
      client: MockClient((request) async {
        return http.Response.bytes(_pixelPng, 200);
      }),
      directoryProvider: () async => tempDir,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: DiskCachedImage(
            url: 'https://example.com/pixel.png',
            cacheKey: 'pixel',
            cache: cache,
            width: 24,
            height: 24,
          ),
        ),
      );
      await _pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    });

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('cache-hit remount issues no HTTP requests', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'disk_cached_image_widget',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    var requests = 0;
    final cache = DiskImageCache(
      client: MockClient((request) async {
        requests++;
        return http.Response.bytes(_pixelPng, 200);
      }),
      directoryProvider: () async => tempDir,
    );

    await tester.runAsync(() async {
      final warm = await cache.fetch(
        url: Uri.parse('https://example.com/hit.png'),
        cacheKey: 'hit',
      );
      expect(warm.downloaded, isTrue);
      expect(requests, 1);

      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          home: DiskCachedImage(
            url: 'https://example.com/hit.png',
            cacheKey: 'hit',
            cache: cache,
            width: 4,
            height: 4,
          ),
        ),
      );

      await mount();
      await _pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(requests, 1);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await mount();
      await _pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(requests, 1);
    });
  });

  testWidgets('shows the placeholder while a fetch is pending', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'disk_cached_image_widget',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final gate = Completer<http.Response>();
    final cache = DiskImageCache(
      client: MockClient((request) => gate.future),
      directoryProvider: () async => tempDir,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: DiskCachedImage(
            url: 'https://example.com/pending.png',
            cacheKey: 'pending',
            cache: cache,
            placeholder: const Text('loading'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('loading'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      gate.complete(http.Response.bytes(_pixelPng, 200));
      await _pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.text('loading'), findsNothing);
    });
  });

  testWidgets('fetch error invokes the provided errorBuilder', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'disk_cached_image_widget',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final cache = DiskImageCache(
      client: MockClient((request) async => http.Response('nope', 500)),
      directoryProvider: () async => tempDir,
    );

    await tester.runAsync(() async {
      Object? capturedError;
      await tester.pumpWidget(
        MaterialApp(
          home: DiskCachedImage(
            url: 'https://example.com/error.png',
            cacheKey: 'error',
            cache: cache,
            errorBuilder: (context, error, stackTrace) {
              capturedError = error;
              return const Text('failed');
            },
          ),
        ),
      );
      await _pumpUntil(tester, () => find.text('failed').evaluate().isNotEmpty);
      expect(capturedError, isA<HttpException>());
    });
  });

  testWidgets('malformed url flows to the provided errorBuilder', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'disk_cached_image_widget',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final cache = DiskImageCache(
      client: MockClient((request) async {
        return http.Response.bytes(_pixelPng, 200);
      }),
      directoryProvider: () async => tempDir,
    );

    await tester.runAsync(() async {
      Object? capturedError;
      await tester.pumpWidget(
        MaterialApp(
          home: DiskCachedImage(
            url: 'http://[::1',
            cacheKey: 'bad-url',
            cache: cache,
            errorBuilder: (context, error, stackTrace) {
              capturedError = error;
              return const Text('bad url');
            },
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('bad url').evaluate().isNotEmpty,
      );
      expect(capturedError, isA<ArgumentError>());
    });
  });

  testWidgets('refreshed image renders the new file bytes', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'disk_cached_image_widget',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    var requests = 0;
    late List<int> redPng;
    late List<int> bluePng;
    final cache = DiskImageCache(
      client: MockClient((request) async {
        requests++;
        return http.Response.bytes(requests == 1 ? redPng : bluePng, 200);
      }),
      directoryProvider: () async => tempDir,
    );

    await tester.runAsync(() async {
      redPng = await _solidPng(const ui.Color(0xFFFF0000));
      bluePng = await _solidPng(const ui.Color(0xFF0000FF));

      Widget build(Duration? maxAge) => MaterialApp(
        home: DiskCachedImage(
          url: 'https://example.com/refresh.png',
          cacheKey: 'refresh',
          cache: cache,
          width: 4,
          height: 4,
          maxAge: maxAge,
        ),
      );

      await tester.pumpWidget(build(null));
      await _pumpUntilImage(tester);
      expect(await _renderedPixel(tester), const ui.Color(0xFFFF0000));
      expect(requests, 1);

      await File(
        '${tempDir.path}/disk_cached_image/refresh',
      ).setLastModified(DateTime.now().subtract(const Duration(minutes: 5)));

      await tester.pumpWidget(build(const Duration(minutes: 1)));
      await _pumpUntil(tester, () => requests == 2);
      await _pumpUntilPixel(tester, const ui.Color(0xFF0000FF));
    });
  });
}
