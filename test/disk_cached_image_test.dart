import 'dart:convert';
import 'dart:io';

import 'package:disk_cached_image/disk_cached_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final List<int> _pixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('renders the downloaded image', (tester) async {
    late Directory tempDir;
    final cache = DiskImageCache(
      client: MockClient((request) async {
        return http.Response.bytes(_pixelPng, 200);
      }),
      directoryProvider: () async => tempDir,
    );

    await tester.runAsync(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'disk_cached_image_widget',
      );
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
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);

    await tester.runAsync(() => tempDir.delete(recursive: true));
  });
}
