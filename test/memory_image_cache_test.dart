import 'dart:typed_data';

import 'package:disk_cached_image/disk_cached_image.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(int length) => Uint8List(length);

void main() {
  test('stores bytes and reports the size', () {
    final cache = MemoryImageCache(maxBytes: 100);
    cache.put('a', bytes(10));
    cache.put('b', bytes(20));
    expect(cache.length, 2);
    expect(cache.size, 30);
    expect(cache.get('a'), hasLength(10));
  });

  test('evicts the least recently used entry above maxBytes', () {
    final cache = MemoryImageCache(maxBytes: 10);
    cache.put('a', bytes(4));
    cache.put('b', bytes(4));
    cache.get('a');
    cache.put('c', bytes(4));
    expect(cache.get('a'), isNotNull);
    expect(cache.get('b'), isNull);
    expect(cache.get('c'), isNotNull);
    expect(cache.length, 2);
    expect(cache.size, 8);
  });

  test('ignores empty bytes and images above maxBytes', () {
    final cache = MemoryImageCache(maxBytes: 4);
    cache.put('empty', bytes(0));
    cache.put('large', bytes(5));
    expect(cache.length, 0);
    expect(cache.size, 0);
  });

  test('replaces an existing entry without counting it twice', () {
    final cache = MemoryImageCache(maxBytes: 100);
    cache.put('a', bytes(10));
    cache.put('a', bytes(3));
    expect(cache.length, 1);
    expect(cache.size, 3);
  });

  test('remove and clear update the size', () {
    final cache = MemoryImageCache(maxBytes: 100);
    cache.put('a', bytes(10));
    cache.put('b', bytes(20));
    cache.remove('a');
    expect(cache.size, 20);
    cache.clear();
    expect(cache.length, 0);
    expect(cache.size, 0);
  });
}
