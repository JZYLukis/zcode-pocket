// 产物分享（早前批次，方案 A：私有目录+系统分享面板）：
// 核心控制器（全量分块拉取/取消/超限/失败清理）+UI 旅程（产物行入口、
// 进度弹窗取消、图片/html 预览页直分享、截断文本页不给入口）。
// 教训沿用：测试环境未 mock 的 MethodChannel 其 Future 永不完成——
// companion/share 与 path_provider 通道在本文件旅程用例里必须 mock。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/artifact_share.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/companion_client.dart' show BridgeSession;
import 'package:zcode_pocket/transport/conversation.dart' show ConversationState;
import 'package:zcode_pocket/ui/file_preview.dart'
    show HtmlPreviewPage, TextFilePreviewPage;
import 'package:zcode_pocket/ui/share_flow.dart'
    show ArtifactShareDiskPort, shareDisk;
import 'package:zcode_pocket/ui/workflow_runs_page.dart'
    show ArtifactImagePage, WorkflowRunDetailPage, WorkflowRunsPage,
        looksBinaryContent;

void main() {
  // plain test 里用 mock 通道必须先初始化 binding（探针实证：未初始化
  // 取 TestDefaultBinaryMessengerBinding.instance 直接抛错）。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('嗅探窗口 16KB：真实 OOXML 家族标记在 1.7-1.8KB 也可命中（A-H1）',
      () {
    final zip = [0x50, 0x4B, 0x03, 0x04];
    // 审查员实测：真实 docx/pptx 家族目录名在 1.7-1.8KB——1024 窗口
    // 会把 pptx/docx 补成 .zip 打不开。padding 用 NUL（真实 zip 二进制
    // 非 ASCII，也满足家族标记的非字母数字边界）。
    final head1700 = List<int>.generate(
        1700, (i) => 0x00, growable: true);
    head1700.addAll('ppt/slides/s1.xml'.codeUnits);
    expect(ensureArtifactExtension('测试演示', [...zip, ...head1700]),
        '测试演示.pptx');
    // 家族标记加边界：'maxl/' 不误判 xlsx。
    final bogus = [...zip, ...'entry maxl/data'.codeUnits];
    expect(ensureArtifactExtension('归档', bogus), '归档.zip');
    // PK 先于 %PDF：zip 首条目为 stored PDF 时不误判 pdf。
    final zipPdf = [...zip, ...'%PDF-1.4 stored inside'.codeUnits];
    expect(ensureArtifactExtension('包', zipPdf), '包.zip');
  });

  test('totalBytes 完整性：声明总量与实收不符=抛错删除（A-M2）', () async {
    final target = File(
        '${Directory.systemTemp.createTempSync().path}${Platform.pathSeparator}inc.bin');
    await expectLater(
      downloadArtifactToFile(
        read: (offset) async => {
          'dataBase64': base64.encode('abcd'.codeUnits),
          'totalBytes': 10,
          'nextOffset': null,
        },
        target: target,
      ),
      throwsA(isA<ArtifactShareException>()
          .having((e) => e.reason, 'reason', contains('incomplete'))),
    );
    expect(await target.exists(), isFalse, reason: '半截文件必须删除');
  });

  test('ensureArtifactExtension：无扩展名按魔数补/有扩展名不覆盖', () {
    // 已有合法扩展名=原样（不覆盖 agent 命名）。
    expect(ensureArtifactExtension('report.pdf', [0x25, 0x50, 0x44, 0x46]), 'report.pdf');
    // PNG 魔数补后缀（真机验收：无后缀 png 靠魔数侥幸、其余全打不开）。
    expect(ensureArtifactExtension('测试图片', [0x89, 0x50, 0x4E, 0x47, 0x0D]), '测试图片.png');
    expect(ensureArtifactExtension('照片', [0xFF, 0xD8, 0xFF, 0xE0]), '照片.jpg');
    // PDF 允许前导垃圾（%PDF 在窗口内任意偏移）。
    expect(ensureArtifactExtension('测试文档', [0x0A, 0x0A, 0x25, 0x50, 0x44, 0x46]), '测试文档.pdf');
    // OOXML 家族按 zip 首包内目录名区分（真机验收 .bin 事故的兜底层）。
    final zip = [0x50, 0x4B, 0x03, 0x04];
    expect(ensureArtifactExtension('测试表格', [...zip, ...'...xl/workbook'.codeUnits]), '测试表格.xlsx');
    expect(ensureArtifactExtension('测试演示', [...zip, ...'...ppt/slide1'.codeUnits]), '测试演示.pptx');
    expect(ensureArtifactExtension('归档', [...zip, ...'plain entry'.codeUnits]), '归档.zip');
    // 无命中=原样（宁缺勿错）。
    expect(ensureArtifactExtension('普通产物', 'hello'.codeUnits), '普通产物');
  });

  test('looksBinaryContent：NUL/非法 UTF-8=二进制，纯文本/中文=文本', () {
    expect(looksBinaryContent([0x50, 0x4B, 0x00, 0x03]), isTrue,
        reason: 'NUL 字节（zip 家族内常见）');
    expect(looksBinaryContent([0xFF, 0xD8, 0xFF, 0xE0]), isTrue,
        reason: '非法 UTF-8 序列（JPEG 头）');
    expect(looksBinaryContent(utf8.encode('hello world')), isFalse);
    expect(looksBinaryContent(utf8.encode('中文内容')), isFalse,
        reason: '合法 UTF-8 中文不误判');
    expect(looksBinaryContent(const []), isFalse);
  });

  test('sanitizeArtifactFileName：非法字符/控制符/首尾点空格/空兜底', () {
    expect(sanitizeArtifactFileName(r'a\b:/c*d?"e<f>g|.txt'),
        'a_b__c_d__e_f_g_.txt');
    expect(sanitizeArtifactFileName('  report..name. '), 'report..name');
    expect(sanitizeArtifactFileName('   '), 'artifact.bin');
    expect(sanitizeArtifactFileName('con:trol\x01x'), 'con_trol_x');
  });

  test('sanitizeArtifactFileName：超长截 64 保扩展名', () {
    final long = 'a' * 100;
    final n = sanitizeArtifactFileName('$long.json');
    expect(n.length, 64);
    expect(n.endsWith('.json'), isTrue, reason: '截断必须保住扩展名');
    final noExt = sanitizeArtifactFileName(long);
    expect(noExt.length, 64);
  });

  group('downloadArtifactToFile', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('zp_artifact_share_');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('多块拼接落盘+返回字节数+最终进度回调', () async {
      final target = File('${tmp.path}${Platform.pathSeparator}out.bin');
      final blocks = {0: utf8.encode('AAA'), 3: utf8.encode('BBB')};
      var received = 0;
      final n = await downloadArtifactToFile(
        read: (offset) async {
          final bytes = blocks[offset];
          if (bytes == null) return {'dataBase64': ''};
          return {
            'dataBase64': base64.encode(bytes),
            'nextOffset': offset == 3 ? -1 : 3,
          };
        },
        target: target,
        onProgress: (r) => received = r,
      );
      expect(n, 6);
      expect(await target.readAsString(), 'AAABBB');
      expect(received, 6, reason: '收尾必须补一次最终进度');
    });

    test('取消：半截文件删除+抛 cancelled', () async {
      final target = File('${tmp.path}${Platform.pathSeparator}cancel.bin');
      var cancelled = false;
      var calls = 0;
      await expectLater(
        downloadArtifactToFile(
          read: (offset) async {
            calls++;
            // 第二次读返回后置取消——第三轮循环顶检测并收场（真实形态：
            // 用户在块间点取消，至多多写一块）。
            if (calls == 2) cancelled = true;
            return {
              'dataBase64': base64.encode(utf8.encode('AA')),
              'nextOffset': calls == 1 ? 2 : 4,
            };
          },
          target: target,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<ArtifactShareException>()
            .having((e) => e.reason, 'reason', 'cancelled')),
      );
      expect(await target.exists(), isFalse, reason: '取消不得留半截文件');
    });

    test('超限：删除+抛 oversized（maxBytes 可注入——测试不造 150MB）',
        () async {
      final target = File('${tmp.path}${Platform.pathSeparator}big.bin');
      await expectLater(
        downloadArtifactToFile(
          read: (offset) async => {
            'dataBase64': base64.encode(List.filled(100, 1)),
            'nextOffset': -1,
          },
          target: target,
          maxBytes: 10,
        ),
        throwsA(isA<ArtifactShareException>()
            .having((e) => e.reason, 'reason', 'oversized')),
      );
      expect(await target.exists(), isFalse, reason: '超限不得留半截文件');
    });

    test('读失败：包装为 read-failed+删除', () async {
      final target = File('${tmp.path}${Platform.pathSeparator}err.bin');
      await expectLater(
        downloadArtifactToFile(
          read: (offset) async => throw StateError('rpc down'),
          target: target,
        ),
        throwsA(isA<ArtifactShareException>()
            .having((e) => e.reason, 'reason', contains('read-failed'))),
      );
      expect(await target.exists(), isFalse);
    });
  });

  test('shareArtifactFile：通道透传 path；false 与 PlatformException 都归 false',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Object?>[];
    Object? handlerResult = true;
    messenger.setMockMethodCallHandler(
      const MethodChannel('companion/share'),
      (call) async {
        calls.add(call.arguments);
        if (handlerResult is Exception) throw handlerResult;
        return handlerResult;
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('companion/share'), null));

    expect(await shareArtifactFile('/x/y.bin'), isTrue);
    expect(calls, [
      {'path': '/x/y.bin'},
    ]);

    handlerResult = false;
    expect(await shareArtifactFile('/x/y.bin'), isFalse);
    handlerResult = PlatformException(code: 'e');
    expect(await shareArtifactFile('/x/y.bin'), isFalse);
  });

  group('widget 旅程', () {
    final shareCalls = <Map<dynamic, dynamic>>[];
    late _MemShareDisk memDisk;

    setUp(() async {
      // testWidgets 假区内真实磁盘 IO 永不完成（教训，探针
      // 实证）——旅程注入内存桩只验到通道边界，真实磁盘往返由上方纯
      // 逻辑组真文件覆盖。
      memDisk = _MemShareDisk();
      shareDisk = memDisk;
      // 静态脚本参数逐例复位（防用例间泄漏）。
      _ShareApp.artifactText = '今日完成 3 项工作';
      _ShareApp.blockCount = 1;
      _ShareApp.nextReadGate = null;
      _ShareApp.artifactBytesOverride = null;
      _ShareApp.artifactsOverride = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // companion/share 必须 mock——未 mock 通道的 Future 永不完成
      // （issue #13 教训）；path_provider 的 mock 通道在假区内可用。
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => r'C:\zp-test-cache',
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('companion/share'),
        (call) async {
          shareCalls.add(call.arguments as Map<dynamic, dynamic>);
          return true;
        },
      );
    });
    tearDown(() async {
      shareDisk = const ArtifactShareDiskPort();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('companion/share'), null);
      shareCalls.clear();
    });

    Widget host(Widget home) {
      final app = _ShareApp();
      app.uiPrefs.debugMarkLoadedForTest();
      return AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: home),
      );
    }

    Future<void> pump(WidgetTester tester, Widget widget) async {
      await tester.pumpWidget(widget);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('产物行：内容产物有分享钮、看板产物没有；弹窗取消不调分享',
        (tester) async {
      // 块数 5：第 1 块立即返回，第 2 块由闸门放行——取消后放行，下载
      // 在下一轮循环顶检测 cancelled 并收场。
      _ShareApp.blockCount = 5;
      final gate = Completer<Map<String, dynamic>>();
      _ShareApp.nextReadGate = gate.future;
      await pump(
        tester,
        host(const WorkflowRunDetailPage(
          sessionId: 's1',
          runId: 'run-1',
          title: '运行',
        )),
      );
      expect(find.byKey(const ValueKey('workflow-artifact-share-art-1')),
          findsOneWidget,
          reason: '内容产物必须有分享入口');
      expect(find.byKey(const ValueKey('workflow-artifact-share-art-dash')),
          findsNothing,
          reason: '看板四类无内容字节，不给分享入口');

      await tester
          .tap(find.byKey(const ValueKey('workflow-artifact-share-art-1')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('正在获取产物…'), findsOneWidget);

      await tester.tap(find.text('取消'));
      // 闸门放行必须给「继续块」（nextOffset>0）——若给终止块，下载会在
      // 下一轮循环顶检测取消之前就正常收场（弹窗成功关闭≠取消路径）。
      gate.complete({
        'dataBase64': base64.encode(utf8.encode('BBB')),
        'nextOffset': 2,
      });
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('正在获取产物…'), findsNothing, reason: '取消即关弹窗');
      expect(shareCalls, isEmpty, reason: '取消不得调起系统分享');
      expect(
        memDisk.files.keys.any((k) => k.endsWith('report.txt')),
        isFalse,
        reason: '取消后不得留产物文件（内存桩视角；真实删除语义由纯逻辑组覆盖）',
      );
    });

    testWidgets('产物行分享成功：全量落盘+调分享面板', (tester) async {
      await pump(
        tester,
        host(const WorkflowRunDetailPage(
          sessionId: 's1',
          runId: 'run-1',
          title: '运行',
        )),
      );
      await tester
          .tap(find.byKey(const ValueKey('workflow-artifact-share-art-1')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(shareCalls.length, 1, reason: '下载完成即调一次系统分享');
      final path = '${shareCalls.first['path']}';
      expect(path, contains('artifacts'));
      expect(utf8.decode(memDisk.files[path]!), '今日完成 3 项工作');
    });

    testWidgets('二进制产物：不支持预览页替代乱码文本页+页内可分享',
        (tester) async {
      // 2026-11-14 验收实录：点 xlsx 产物行 → utf8 allowMalformed 解码
      // = 满屏乱码（用户以为报错）。修=二进制判定进体面提示页。
      _ShareApp.artifactBytesOverride = [
        0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00,
        ...'xl/workbook.xml'.codeUnits,
      ];
      _ShareApp.artifactsOverride = const [
        {'id': 'art-1', 'title': '测试表格', 'kind': '', 'version': 1},
      ];
      addTearDown(() {
        _ShareApp.artifactBytesOverride = null;
        _ShareApp.artifactsOverride = null;
      });
      await pump(
        tester,
        host(const WorkflowRunDetailPage(
          sessionId: 's1',
          runId: 'run-1',
          title: '运行',
        )),
      );
      await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-1')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('artifact-binary-share')), findsOneWidget,
          reason: '二进制产物进不支持预览页（带分享出口）');
      expect(find.textContaining('暂不支持预览'), findsOneWidget);
      expect(find.textContaining('PK'), findsNothing,
          reason: '二进制字节不再被当文本渲染');
      // 页内分享：嗅探补 .xlsx（字节为 PK+xl/）。
      await tester.tap(find.byKey(const ValueKey('artifact-binary-share')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(shareCalls.length, 1);
      expect('${shareCalls.first['path']}'.endsWith('.xlsx'), isTrue);
    });

    testWidgets('后缀兜底：无后缀产物 title 按魔数自动补扩展名', (tester) async {
      // 实测反馈：title="测试图片（PNG·matplotlib）"无后缀 → 下载
      // 后打不开。兜底层按文件头补 .png（不依赖 agent 提示词自觉）。
      _ShareApp.artifactBytesOverride = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A];
      _ShareApp.artifactsOverride = const [
        {'id': 'art-1', 'title': '测试图片', 'kind': '', 'version': 1},
      ];
      addTearDown(() {
        _ShareApp.artifactBytesOverride = null;
        _ShareApp.artifactsOverride = null;
      });
      await pump(
        tester,
        host(const WorkflowRunDetailPage(
          sessionId: 's1',
          runId: 'run-1',
          title: '运行',
        )),
      );
      await tester
          .tap(find.byKey(const ValueKey('workflow-artifact-share-art-1')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(shareCalls.length, 1);
      final path = '${shareCalls.first['path']}';
      expect(path.endsWith('.png'), isTrue,
          reason: 'PNG 魔数+无后缀 title → 分享文件名补 .png');
      expect(memDisk.files[path], isNotNull, reason: '改名后内容随迁');
    });

    testWidgets('图片预览页直分享：内存字节落盘+通道调用', (tester) async {
      final bytes = utf8.encode('PNGDATA');
      await pump(
        tester,
        host(ArtifactImagePage(
          title: 'chart.png',
          bytes: Uint8List.fromList(bytes),
        )),
      );
      await tester.tap(find.byKey(const ValueKey('artifact-image-share')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(shareCalls.length, 1);
      expect(utf8.decode(memDisk.files['${shareCalls.first['path']}']!),
          'PNGDATA');
    });

    testWidgets('html 预览页直分享（debugDisableWebView 走降级分支）',
        (tester) async {
      HtmlPreviewPage.debugDisableWebView = true;
      addTearDown(() => HtmlPreviewPage.debugDisableWebView = false);
      await pump(
        tester,
        host(HtmlPreviewPage(
          title: 'report.html',
          htmlContent: '<html><body>hi</body></html>',
        )),
      );
      await tester.tap(find.byKey(const ValueKey('html-preview-share')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(shareCalls.length, 1);
      expect(
        utf8
            .decode(memDisk.files['${shareCalls.first['path']}']!)
            .contains('<html>'),
        isTrue,
      );
    });

    testWidgets('会话新建文本文件预览页直分享（早前批次）',
        (tester) async {
      await pump(
        tester,
        host(const TextFilePreviewPage(
          title: 'data.md',
          fileName: 'data.md',
          content: '# 数据报告\n共 3 条记录',
        )),
      );
      await tester.tap(find.byKey(const ValueKey('conversation-text-share')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(shareCalls.length, 1);
      expect(utf8.decode(memDisk.files['${shareCalls.first['path']}']!),
          '# 数据报告\n共 3 条记录');
    });

    testWidgets('html 产物截断：预览在场但分享不给（A-M3/B-M1）',
        (tester) async {
      HtmlPreviewPage.debugDisableWebView = true;
      addTearDown(() => HtmlPreviewPage.debugDisableWebView = false);
      _ShareApp.artifactText = '<!doctype html><html><body>报告</body></html>';
      _ShareApp.blockCount = 9;
      addTearDown(() {
        _ShareApp.artifactText = '今日完成 3 项工作';
        _ShareApp.blockCount = 1;
      });
      await pump(
        tester,
        host(const WorkflowRunDetailPage(
          sessionId: 's1',
          runId: 'run-1',
          title: '运行',
        )),
      );
      await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-1')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(HtmlPreviewPage), findsOneWidget,
          reason: 'html 产物仍进预览（截断标记在标题）');
      expect(find.byKey(const ValueKey('html-preview-share')), findsNothing,
          reason: '半份 html 不是完整文件——分享入口必须缺席');
    });

    testWidgets('hub 收集按钮禁用（onCollectPrompt null=readOnly 形态）',
        (tester) async {
      // B-/C-：conversation 侧 readOnly→onCollectPrompt=null（一行
      // 接线），此处直灌 null 验证 hub 禁用形态。
      await pump(
        tester,
        host(const WorkflowRunsPage(
          sessionId: 's1',
          downloadsHub: true,
        )),
      );
      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('hub-collect-button')),
      );
      expect(btn.onPressed, isNull,
          reason: 'readOnly 会话不可发送——收集按钮必须禁用');
    });

    testWidgets('文本预览页：未截断给分享、截断不给（半份内容不是文件）',
        (tester) async {
      // 块数 9>8：预览 8 块上限命中 → 截断（按块计，与块字节大小无关）。
      _ShareApp.blockCount = 9;
      await pump(
        tester,
        host(const WorkflowRunDetailPage(
          sessionId: 's1',
          runId: 'run-1',
          title: '运行',
        )),
      );
      await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-1')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('内容过长已截断'), findsOneWidget);
      expect(find.byKey(const ValueKey('artifact-text-share')), findsNothing,
          reason: '截断的预览不是完整文件，不给分享入口');

      // 回详情页（pumpWidget 复用元素树——不 pop 的话预览页仍在栈顶，
      // 下方产物行 offstage 不可点）。
      await tester.pageBack();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // 未截断（1 块）：入口在场且可分享。
      _ShareApp.blockCount = 1;
      await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-1')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
          find.byKey(const ValueKey('artifact-text-share')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('artifact-text-share')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(shareCalls.length, 1);
      expect(utf8.decode(memDisk.files['${shareCalls.first['path']}']!),
          '今日完成 3 项工作');
    });
  });
}

/// 内存桩磁盘（testWidgets 假区内真实 IO 永不完成—— 教训）：
/// 只复刻「块循环到通道边界」的形状（取消/终止语义），真实磁盘往返
/// （流式写/删除清理/超限）由纯逻辑组真文件覆盖。
class _MemShareDisk extends ArtifactShareDiskPort {
  final files = <String, List<int>>{};

  @override
  Future<void> ensureTarget(File target) async {}

  @override
  Future<void> writeBytes(File target, List<int> bytes) async {
    files[target.path] = bytes;
  }

  @override
  Future<List<int>> readHead(File target, [int limit = 1024]) async =>
      (files[target.path] ?? const <int>[]).take(limit).toList();

  @override
  Future<File> renameTo(File from, String newName) async {
    final bytes = files.remove(from.path);
    final moved = File(
      '${from.parent.path}${Platform.pathSeparator}$newName',
    );
    if (bytes != null) files[moved.path] = bytes;
    return moved;
  }

  @override
  Future<int> download({
    required Future<dynamic> Function(int offset) read,
    required File target,
    void Function(int received)? onProgress,
    bool Function()? isCancelled,
    int maxBytes = kMaxArtifactShareBytes,
  }) async {
    var received = 0;
    var offset = 0;
    final out = <int>[];
    while (true) {
      if (isCancelled?.call() ?? false) {
        files.remove(target.path);
        throw const ArtifactShareException('cancelled');
      }
      final res = await read(offset);
      final b64 = '${(res is Map ? res['dataBase64'] : '') ?? ''}';
      if (b64.isEmpty) break;
      final chunk = base64.decode(b64);
      out.addAll(chunk);
      received += chunk.length;
      onProgress?.call(received);
      final next =
          (res is Map ? (res['nextOffset'] as num?)?.toInt() : null) ?? -1;
      if (next <= offset || next <= 0) break;
      offset = next;
    }
    files[target.path] = out;
    return received;
  }
}

/// 最小 AppState：只供 WorkflowRunDetailPage 三查询 + 预览读取。
/// artifacts 固定两条：内容产物 art-1（report.txt）+ 看板产物 art-dash。
///
/// ArtifactRead 脚本（静态参数，setUp 逐例复位）：每块返回全文字节，
/// [blockCount] 块后 dataBase64 置空——块数 >8 即触发预览 8 块截断
/// （截断按块计），=1 即单块完整（nextOffset=-1）。
class _ShareApp extends AppState {
  static String artifactText = '今日完成 3 项工作';
  static int blockCount = 1;
  static Future<Map<String, dynamic>>? nextReadGate;
  /// 非空=分块返回这段固定字节（后缀嗅探旅程用），忽略 artifactText。
  static List<int>? artifactBytesOverride;
  /// 非空=替换产物清单（后缀嗅探旅程：title 无后缀形态）。
  static List<Map<String, dynamic>>? artifactsOverride;

  @override
  bool get loaded => true;
  @override
  BridgeSession? get bridge => null;

  final ConversationState projectionState = ConversationState();

  @override
  Map<String, ConversationState> get conversationStates =>
      {'s1': projectionState};

  @override
  Future<dynamic> workflowRunEvents(String sessionId, String runId,
      {int? afterSequence, int? limit}) async {
    return const {'events': [], 'hasMore': false};
  }

  @override
  Future<dynamic> workflowRunArtifacts(String sessionId, String runId) async {
    return {
      'artifacts': artifactsOverride ??
          const [
            {'id': 'art-1', 'title': 'report.txt', 'kind': 'text', 'version': 1},
            {'id': 'art-dash', 'title': 'stats', 'kind': 'chart', 'version': 1},
          ],
    };
  }

  @override
  Future<dynamic> workflowRunArtifactRead(
    String sessionId,
    String runId,
    String artifactId, {
    required int version,
    required int offset,
    required int limit,
  }) async {
    if (artifactId != 'art-1') throw StateError('no bytes');
    final blockIndex = offset;
    if (blockIndex >= blockCount) return {'dataBase64': ''};
    if (blockIndex == 1 && nextReadGate != null) {
      final gated = await nextReadGate!;
      nextReadGate = null;
      return gated;
    }
    final bytes = artifactBytesOverride ?? utf8.encode(artifactText);
    return {
      'dataBase64': base64.encode(bytes),
      'nextOffset': blockIndex + 1 >= blockCount ? -1 : blockIndex + 1,
    };
  }
}
