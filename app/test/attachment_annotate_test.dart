import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/attachment_annotate_page.dart';

/// 截图圈点标注（6.6④，ADR 0062）：绘制/撤销/清空/保存合成与页面旅程。
/// toImage/instantiateImageCodec 走真实引擎异步——生成与保存断言在
/// runAsync 内完成（游览 _snap 同款约束）。

Future<Uint8List> _solidPng(int w, int h, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

Widget _host(Uint8List png, [void Function(Uint8List?)? onResult]) =>
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => TextButton(
          key: const ValueKey('open'),
          onPressed: () async {
            final result = await Navigator.of(context).push<Uint8List>(
              MaterialPageRoute(
                builder: (_) => AttachmentAnnotatePage(
                  imageBytes: png,
                  fileName: 'shot.png',
                ),
              ),
            );
            onResult?.call(result);
          },
          child: const Text('开'),
        ),
      ),
    );

Future<void> _openEditor(WidgetTester tester, Uint8List png) async {
  tester.view.physicalSize = const Size(375, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(png));
  await tester.tap(find.byKey(const ValueKey('open')));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  tearDown(() {
    AttachmentAnnotatePage.debugImage = null;
    AttachmentAnnotatePage.debugInitialStrokes = null;
  });

  testWidgets('绘制→撤销→清空：笔迹增删与画布交互不溢出', (tester) async {
    final png = await tester.runAsync(
      () => _solidPng(300, 200, const Color(0xFFDDDDDD)),
    );
    expect(png, isNotNull, reason: 'runAsync 必须产出测试底图');
    await _openEditor(tester, png!);
    expect(find.byKey(const ValueKey('annotate-canvas')), findsOneWidget);

    final canvas = find.byKey(const ValueKey('annotate-canvas'));
    await tester.dragFrom(
      tester.getCenter(canvas) + const Offset(-40, -20),
      const Offset(80, 40),
    );
    await tester.pump();
    await tester.dragFrom(
      tester.getCenter(canvas) + const Offset(0, 20),
      const Offset(50, -30),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('annotate-undo')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('annotate-clear')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('色板换色与选中态', (tester) async {
    final png = await tester.runAsync(
      () => _solidPng(300, 200, const Color(0xFFDDDDDD)),
    );
    await _openEditor(tester, png!);
    await tester.tap(find.byKey(const ValueKey('annotate-color-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('annotate-color-2')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存：pop 带回非空合成 PNG', (tester) async {
    final png = await tester.runAsync(
      () => _solidPng(300, 200, const Color(0xFFDDDDDD)),
    );
    // fake 异步里 instantiateImageCodec 不回包——预解码底图+预置笔迹
    // 走真实保存合成路径（runAsync 窗口内冲洗）。
    final image = await tester.runAsync(() => _decode(png!));
    AttachmentAnnotatePage.debugImage = image;
    AttachmentAnnotatePage.debugInitialStrokes = const [
      AnnotateStroke(
        color: Color(0xFFE5484D),
        width: 3,
        points: [Offset(20, 20), Offset(90, 60), Offset(150, 100)],
      ),
    ];
    final captured = <Uint8List?>[];
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(png!, captured.add));
    await tester.tap(find.byKey(const ValueKey('open')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('annotate-save')));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    final result = captured.isNotEmpty ? captured.first : null;
    expect(result, isNotNull, reason: '保存必须 pop 带回合成字节');
    expect(result!.length, greaterThan(8));
    expect(result.length, lessThan(20 * 1024 * 1024));
  });

  test('renderAnnotatedImage：全分辨率与笔迹换算（真实引擎合成）', () async {
    final done = Completer<void>();
    unawaited(() async {
      final base = await _solidPng(400, 300, const Color(0xFFEEEEEE));
      final image = await _decode(base);
      final edited = await renderAnnotatedImage(
        image: image,
        strokes: const [
          AnnotateStroke(
            color: Color(0xFFE5484D),
            width: 3,
            points: [Offset(10, 10), Offset(60, 40), Offset(120, 80)],
          ),
          AnnotateStroke(
            color: Color(0xFF3B82F6),
            width: 3,
            points: [Offset(50, 50)],
          ),
        ],
        displayToImageScale: 2.0,
      );
      expect(edited, isNotNull);
      final decoded = await _decode(edited!);
      expect(decoded.width, 400, reason: '合成保持原图分辨率');
      expect(decoded.height, 300);
      done.complete();
    }());
    await done.future.timeout(const Duration(seconds: 10));
  });
}
