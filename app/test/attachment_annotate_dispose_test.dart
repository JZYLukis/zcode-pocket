// 2026-11-08 批 #18（低）：标注页 ui.Image 未释放（全分辨率
// 底图+合成图持原生内存）——退页必须 dispose；测试缝 debugImage 属
// 跨用例共享（既有约定）不得被页面销毁。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/attachment_annotate_page.dart';

Future<Uint8List> _solidPng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFFDDDDDD),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  tearDown(() {
    AttachmentAnnotatePage.debugImage = null;
    AttachmentAnnotatePage.debugInitialStrokes = null;
    AttachmentAnnotatePage.debugOnDecoded = null;
  });

  testWidgets('退页释放解码出的 ui.Image（原生内存）', (tester) async {
    final png = await tester.runAsync(() => _solidPng(120, 80));
    ui.Image? decoded;
    AttachmentAnnotatePage.debugOnDecoded = (img) => decoded = img;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AttachmentAnnotatePage(imageBytes: png!, fileName: 'a.png'),
      ),
    );
    // 真实解码走引擎异步：runAsync 内放行。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(decoded, isNotNull, reason: '解码回调已触发');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(decoded!.debugDisposed, isTrue,
        reason: '页面 dispose 必须释放底图 ui.Image');
  });

  testWidgets('测试缝 debugImage（跨用例共享）不被页面销毁', (tester) async {
    final image = await tester.runAsync(
      () => createTestImage(width: 8, height: 8),
    );
    AttachmentAnnotatePage.debugImage = image;
    AttachmentAnnotatePage.debugInitialStrokes = const [
      AnnotateStroke(
        color: Color(0xFF000000),
        width: 2,
        points: [Offset(1, 1), Offset(2, 2)],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AttachmentAnnotatePage(
          imageBytes: Uint8List(0),
          fileName: 'b.png',
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('annotate-canvas')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(image!.debugDisposed, isFalse,
        reason: '测试缝 image 归测试持有，页面不得 dispose');
  });
}
