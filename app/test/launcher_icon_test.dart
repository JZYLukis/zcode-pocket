import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, int>{
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  test('启动图标五档均为全黑不透明底', () async {
    for (final entry in sizes.entries) {
      final file = File(
        'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
      );
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      codec.dispose();
      expect(image.width, entry.value, reason: '${entry.key} 宽度');
      expect(image.height, entry.value, reason: '${entry.key} 高度');

      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      for (var i = 3; i < pixels.length; i += 4) {
        expect(pixels[i], 255, reason: '${entry.key} 第 ${i ~/ 4} 像素透明度');
      }

      for (final corner in <(int, int)>[
        (0, 0),
        (image.width - 1, 0),
        (0, image.height - 1),
        (image.width - 1, image.height - 1),
      ]) {
        final offset = (corner.$2 * image.width + corner.$1) * 4;
        expect(
          pixels.sublist(offset, offset + 4),
          <int>[0, 0, 0, 255],
          reason: '${entry.key} 四角必须为全黑不透明',
        );
      }
      image.dispose();
    }
  });

  test('POCKET 在 192px 母版中保持放大的可见尺寸', () async {
    final file = File(
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    );
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    codec.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = data!.buffer.asUint8List();

    var minX = image.width;
    var minY = image.height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 130; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final offset = (y * image.width + x) * 4;
        if (pixels[offset] > 220 &&
            pixels[offset + 1] > 220 &&
            pixels[offset + 2] > 220 &&
            pixels[offset + 3] == 255) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    expect(maxX, greaterThanOrEqualTo(0), reason: '色带中必须存在 POCKET 白字');
    expect(maxX - minX + 1, greaterThanOrEqualTo(90), reason: 'POCKET 宽度');
    expect(maxY - minY + 1, greaterThanOrEqualTo(15), reason: 'POCKET 高度');
    expect((minX + maxX) / 2, closeTo(96, 2), reason: 'POCKET 水平居中');
    image.dispose();
  });
}
