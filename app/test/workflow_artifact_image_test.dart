// 工作流产物图片预览——artifactRead 是
// 纯数据读取（零 token、不进模型上下文）。纯函数（扩展名判定/魔数嗅探）
// 直测；ArtifactImagePage 渲染真 PNG 与解码失败降级各一例。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/workflow_runs_page.dart';

/// 1×1 红色像素 PNG（魔数齐全，Image.memory 可真解码）。
final Uint8List _png1x1 = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('artifactLooksImageByExtension', () {
    test('支持集命中（大小写不敏感）', () {
      expect(artifactLooksImageByExtension('report.png'), isTrue);
      expect(artifactLooksImageByExtension('Photo.JPG'), isTrue);
      expect(artifactLooksImageByExtension('a.b.JPEG'), isTrue);
      expect(artifactLooksImageByExtension('chart.webp'), isTrue);
      expect(artifactLooksImageByExtension('anim.gif'), isTrue);
      expect(artifactLooksImageByExtension('legacy.bmp'), isTrue);
    });
    test('非图片与无扩展名不命中（SVG 明确排除）', () {
      expect(artifactLooksImageByExtension('index.html'), isFalse);
      expect(artifactLooksImageByExtension('vector.svg'), isFalse,
          reason: 'SVG 不在 Flutter 原生支持集，走文本/提示路径');
      expect(artifactLooksImageByExtension('data.json'), isFalse);
      expect(artifactLooksImageByExtension('noext'), isFalse);
      expect(artifactLooksImageByExtension('trailing.'), isFalse);
    });
  });

  group('sniffImageMagic（扩展名缺失/被骗时的兜底）', () {
    test('五格式魔数命中', () {
      expect(
          sniffImageMagic([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), isTrue);
      expect(sniffImageMagic([0xFF, 0xD8, 0xFF, 0xE0]), isTrue);
      expect(sniffImageMagic([0x47, 0x49, 0x46, 0x38, 0x39]), isTrue);
      expect(
        sniffImageMagic([
          0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
        ]),
        isTrue,
      );
      expect(sniffImageMagic([0x42, 0x4D, 0x00, 0x00]), isTrue);
    });
    test('文本与截断字节不命中', () {
      expect(sniffImageMagic(utf8.encode('<html><body>')), isFalse);
      expect(sniffImageMagic([0x89, 0x50]), isFalse, reason: '过短');
      expect(sniffImageMagic(const []), isFalse);
      // RIFF 但不是 WEBP（如 WAV）不得误进图片路径。
      expect(
        sniffImageMagic([
          0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
        ]),
        isFalse,
      );
    });
  });

  group('ArtifactImagePage', () {
    Future<void> pump(
      WidgetTester tester,
      Uint8List bytes, {
      String title = 'plot.png',
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ArtifactImagePage(title: title, bytes: bytes),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('真 PNG 渲染出 Image，无降级文案', (tester) async {
      await pump(tester, _png1x1);
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('图片解码失败'), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget,
          reason: '双指缩放容器在场');
    });

    testWidgets('损坏字节走人话降级（不白屏不崩）', (tester) async {
      await pump(tester, Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x99]));
      // 解码是异步流：有界泵等 errorBuilder 落帧。
      var degraded = false;
      for (var i = 0; i < 40; i++) {
        if (find.textContaining('图片解码失败').evaluate().isNotEmpty) {
          degraded = true;
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(degraded, isTrue, reason: '解码失败必须出人话，不得无限等待');
    });

    testWidgets('英文界面降级文案走翻译', (tester) async {
      L10n.setTestLocale('en-US');
      addTearDown(() => L10n.setTestLocale('zh-CN'));
      await pump(tester, Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x99]));
      var degraded = false;
      for (var i = 0; i < 40; i++) {
        if (find.textContaining('not supported').evaluate().isNotEmpty) {
          degraded = true;
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(degraded, isTrue);
    });
  });

  group('readArtifactBlocks 分块循环', () {
    // 公开同步终审抓出的缺陷红绿：无扩展名图片（魔数命中）>4MiB 此前
    // 被 8 块上限静默截断；恰好 16MiB 的完整图片此前误报过大。
    Future<ArtifactBlocks> run(
      String name,
      List<int> full, {
      int chunk = 512 * 1024,
    }) {
      final r = readArtifactBlocks(
        name: name,
        read: ({required int offset, required int blockLimit}) async => {
          'dataBase64': base64Encode(
            full.sublist(offset, (offset + chunk).clamp(0, full.length)),
          ),
          'nextOffset':
              offset + chunk < full.length ? offset + chunk : null,
        },
      );
      // 同步桩：直接驱动到完成。
      return r;
    }

    test('无扩展名图片（魔数命中）5MiB 读全不截断', () async {
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ...List<int>.filled(5 * 1024 * 1024, 0x41),
      ];
      final r = await run('screenshot-dump', png);
      expect(r.isImage, isTrue);
      expect(r.oversized, isFalse);
      expect(r.truncated, isFalse, reason: '修复前红：8 块=4MiB 静默截断');
      expect(r.bytes.length, png.length);
    });

    test('恰好 16MiB 的完整图片不误报过大', () async {
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ...List<int>.filled(16 * 1024 * 1024 - 8, 0x42),
      ];
      final r = await run('big.png', png);
      expect(r.oversized, isFalse, reason: '修复前红：读尽仍报过大');
      expect(r.bytes.length, png.length);
    });

    test('图片 >16MiB 且仍有后续 → 超限标志', () async {
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ...List<int>.filled(17 * 1024 * 1024, 0x43),
      ];
      final r = await run('huge.png', png);
      expect(r.oversized, isTrue);
    });

    test('文本 8 块截断置位', () async {
      final txt = List<int>.filled(9 * 512 * 1024, 0x54); // 'T'
      final r = await run('notes.txt', txt);
      expect(r.isImage, isFalse);
      expect(r.truncated, isTrue);
      expect(r.bytes.length, 8 * 512 * 1024);
    });
  });
}

