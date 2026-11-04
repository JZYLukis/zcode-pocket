import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/diff_viewer_page.dart';
import 'package:zcode_pocket/ui/file_preview.dart';

/// 生成文件预览·网页档（file-preview-1，2026-10-29 用户拍板「只做 html
/// 的部分」）：协议无任意文件字节读取通道——唯一原生路径=新建 html 全文
/// 随 fileChanges 到达，本地 WebView 渲染（零提示词零额度）。图片/PDF
/// 档经用户拍板不做。本文件锁：纯函数（全文拼装/扩展名判定/导航白名单）
/// + 旅程（新建 html 行进渲染页、编辑 html 与代码文件仍进 diff）。

class _Bridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-preview';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _PreviewApp extends AppState {
  _PreviewApp(this.rows, this.fileChangesResult);

  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> fileChangesResult;

  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  BridgeSession? get bridge => _Bridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspaceIdentity': 'ws-preview',
    'workspacePath': 'D:/示例项目',
  };
  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: {
          'title': '预览测试',
          'control': {'phase': 'completed'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    Map<String, dynamic>? target,
  }) async => fileChangesResult;
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: const ConversationPage(sessionId: 's1', title: '预览测试'),
  ),
);

Map<String, dynamic> _newHtmlItem() => {
  'path': 'report/index.html',
  'additions': 2,
  'deletions': 0,
  'writeCount': 1,
  'toolNames': ['Write'],
  'patches': [
    {
      'oldStart': 0,
      'oldLines': 0,
      'newStart': 1,
      'newLines': 2,
      'lines': ['+<!doctype html>', '+<h1>报告页</h1>'],
    },
  ],
};

Map<String, dynamic> _editedHtmlItem() => {
  'path': 'report/old.html',
  'additions': 1,
  'deletions': 1,
  'writeCount': 1,
  'toolNames': ['Edit'],
  'patches': [
    {
      'oldStart': 5,
      'oldLines': 1,
      'newStart': 5,
      'newLines': 1,
      'lines': ['-<h1>旧标题</h1>', '+<h1>新标题</h1>'],
    },
  ],
};

Map<String, dynamic> _dartItem() => {
  'path': 'lib/main.dart',
  'additions': 3,
  'deletions': 1,
  'writeCount': 1,
  'toolNames': ['Edit'],
  'patches': [
    {
      'oldStart': 10,
      'oldLines': 1,
      'newStart': 10,
      'newLines': 3,
      'lines': ['-旧行', '+新行1', '+新行2'],
    },
  ],
};

Map<String, dynamic> _changesResult() => {
  'files': 3,
  'additions': 6,
  'deletions': 2,
  'items': [_newHtmlItem(), _editedHtmlItem(), _dartItem()],
};

List<Map<String, dynamic>> _cardRows() => [
  {'rowId': 1, 'kind': 'userInput', 'text': '生成报告'},
  {
    'rowId': 2,
    'kind': 'turnHeader',
    'state': 'completedSuccess',
    'entityId': 'e1',
    'fileChanges': {'files': 3, 'additions': 6, 'deletions': 2},
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('纯函数', () {
    test('assembleNewFileText：新建文件拼全文，编辑/空返回 null', () {
      expect(
        assembleNewFileText([
          {
            'lines': ['+<!doctype html>', '+<h1>你好</h1>'],
          },
        ]),
        '<!doctype html>\n<h1>你好</h1>',
      );
      // 编辑文件（含删除行）→ 宁缺勿半。
      expect(
        assembleNewFileText([
          {
            'lines': ['-旧', '+新'],
          },
        ]),
        isNull,
      );
      expect(assembleNewFileText([]), isNull);
      // 纯插入编辑（无删除行但带 jsdiff 默认 4 行
      // 上下文）→ 不是新建全文，宁进 diff。
      expect(
        assembleNewFileText([
          {
            'lines': [' <!doctype html>', '+<p>追加的一节</p>', ' </body>'],
          },
        ]),
        isNull,
        reason: '上下文行（空格前缀）混入=编辑 diff 非整文件新增',
      );
      expect(
        assembleNewFileText([
          {'lines': []},
        ]),
        isNull,
      );
      expect(
        assembleNewFileText([
          {'lines': [42]},
        ]),
        isNull,
        reason: '非字符串行守卫',
      );
    });

    test('assembleNewFileText：jsdiff 无尾换行标记行跳过（C2）', () {
      // 官方夹具实证 `\ No newline at end of file` 随 lines 真实到达
      // （file-tool-port.test.ts:688）——修复前该标记行使整体返回 null，
      // 无尾换行的新建 html 预览静默降级 diff。
      expect(
        assembleNewFileText([
          {
            'lines': ['+<h1>报告</h1>', r'\ No newline at end of file'],
          },
        ]),
        '<h1>报告</h1>',
      );
      // 标记行不掩盖编辑形态：删除/上下文行混入仍宁进 diff。
      expect(
        assembleNewFileText([
          {
            'lines': ['-旧', '+新', r'\ No newline at end of file'],
          },
        ]),
        isNull,
      );
      expect(
        assembleNewFileText([
          {
            'lines': [
              ' <!doctype html>',
              '+<p>追加</p>',
              r'\ No newline at end of file',
            ],
          },
        ]),
        isNull,
        reason: '上下文行（空格前缀）混入=编辑 diff 非整文件新增',
      );
      // 只有标记无内容行 → 仍 null。
      expect(
        assembleNewFileText([
          {'lines': [r'\ No newline at end of file']},
        ]),
        isNull,
      );
    });

    test('injectPreviewCsp：connect-src 关死且注入 head（review-fix-1 安全组）', () {
      final injected = injectPreviewCsp('<html><head><title>x</title></head><body>y</body></html>');
      expect(injected, contains("connect-src 'none'"));
      expect(injected.indexOf('Content-Security-Policy'),
          lessThan(injected.indexOf('<title>')));
      // 无 head 时骨架注入，内容不丢。
      expect(injectPreviewCsp('<h1>x</h1>'), contains('<h1>x</h1>'));
    });

    test('injectPreviewCsp：<header>/注释劫持与 quirks 防护（C1/C2）', () {
      // `<header>` 标签不得劫持（修复前 meta 插进 header 内=body，CSP
      // 被 Chromium 忽略=防线整页静默失效）→ 骨架注入。
      final headerPage = injectPreviewCsp('<header>导航</header><main>正文</main>');
      expect(headerPage, startsWith('<!DOCTYPE html><html><head>'),
          reason: '无 head 文档须包骨架，meta 落骨架 head 内');
      expect(headerPage, contains('<header>导航</header>'));
      // 注释里的 `<head>` 不算：meta 必须落在真 head 开标签之后，且注释
      // 原文不被改动（修复前 meta 插进注释内部）。真 head 为大写+带属性
      // 形态一并覆盖（旧 indexOf 大小写敏感漏检）。
      final commented = injectPreviewCsp(
        '<!-- <head> --><html><HEAD lang="en"><title>t</title></HEAD></html>',
      );
      expect(commented, contains('<!-- <head> -->'),
          reason: '注释原文不得被注入破坏');
      expect(
        commented.indexOf('Content-Security-Policy'),
        greaterThan(commented.indexOf('<!-- <head> -->')),
        reason: 'meta 必须落在注释之后的真 head 内',
      );
      expect(
        commented.indexOf('Content-Security-Policy'),
        lessThan(commented.indexOf('<title')),
      );
      // 无 head 且带 doctype：骨架注入避免 meta 先于 doctype 触发 quirks。
      final doctypeOnly = injectPreviewCsp('<!DOCTYPE html><h1>x</h1>');
      expect(doctypeOnly, startsWith('<!DOCTYPE html><html><head>'));
      expect(doctypeOnly, contains('<h1>x</h1>'));
    });

    test('isRenderableHtmlPath：html/htm/xhtml 大小写不敏感', () {
      expect(isRenderableHtmlPath('a/b/index.html'), isTrue);
      expect(isRenderableHtmlPath('a/Report.HTM'), isTrue);
      expect(isRenderableHtmlPath('a/page.XHTML'), isTrue);
      expect(isRenderableHtmlPath('a/b/main.dart'), isFalse);
      expect(isRenderableHtmlPath('a/tpl.html.j2'), isFalse);
    });

    test('渲染页导航白名单：只放行 WebView 内部协议，外链全拦', () {
      expect(isHtmlPreviewNavAllowed(Uri.parse('about:blank')), isTrue);
      expect(isHtmlPreviewNavAllowed(Uri.parse('data:text/plain,x')), isTrue);
      expect(isHtmlPreviewNavAllowed(Uri.parse('blob:x')), isTrue);
      expect(
        isHtmlPreviewNavAllowed(Uri.parse('https://zcode.z.ai/')),
        isFalse,
        reason: '渲染页不是浏览入口，官方域也不放行跳转',
      );
      expect(isHtmlPreviewNavAllowed(Uri.parse('https://evil.com')), isFalse);
      expect(isHtmlPreviewNavAllowed(Uri.parse('intent://x')), isFalse);
      expect(isHtmlPreviewNavAllowed(null), isFalse);
    });

    test('parseVisualizeSegments：官方指令与变体分段；未闭合不动', () {
      // 官方 ::visualize + 常见手误 ::visualizer 都消费（显示层裁量）。
      final segs = parseVisualizeSegments(
        '前文\n\n::visualize{"path":"/work/demo.html"}\n\n后文',
      );
      expect(segs.length, 3);
      expect(segs[0].text, contains('前文'));
      expect(segs[1].path, '/work/demo.html');
      expect(segs[2].text, contains('后文'));
      final one = parseVisualizeSegments(
        '::visualizer{"path":"G:\\demo\\chart.html","title":"t"}',
      );
      expect(one.length, 1);
      expect(one.first.path, contains('chart.html'));
      // 无指令=单文本段（零开销路径）。
      expect(parseVisualizeSegments('普通正文').length, 1);
      expect(parseVisualizeSegments('普通正文').first.text, '普通正文');
      // 未闭合（流式中）不消费。
      expect(
        parseVisualizeSegments('::visualize{"path":"/x.html"').first.text,
        contains('::visualize'),
      );
    });

    test('visualizePathMatches：绝对/相对/反斜杠尾部匹配', () {
      expect(
        visualizePathMatches('/g/work/demo.html', 'work/demo.html'),
        isTrue,
      );
      expect(
        visualizePathMatches('G:\\demo\\chart.html', 'demo/chart.html'),
        isTrue,
      );
      expect(visualizePathMatches('/a/b.html', '/c/d.html'), isFalse);
    });

    test('visualizePathMatches：段边界——裸后缀不误配（C1/C2）', () {
      // 修复前：`preindex.html`.endsWith(`index.html`)=true → 多文件轮
      // 打开错误文件且无感知。
      expect(visualizePathMatches('preindex.html', 'index.html'), isFalse);
      expect(visualizePathMatches('/work/preindex.html', 'index.html'), isFalse);
      expect(visualizePathMatches('index.html', 'preindex.html'), isFalse);
      // 段边界匹配保持（叶名=对方完整尾段才命中）。
      expect(visualizePathMatches('/work/index.html', 'index.html'), isTrue);
      expect(
        visualizePathMatches('report/index.html', 'index.html'),
        isTrue,
        reason: '条目路径以指令为尾段（带 / 边界）',
      );
    });
  });

  testWidgets('旅程：::visualize 指令渲染成卡片，点取本轮全文进渲染页', (
    tester,
  ) async {
    HtmlPreviewPage.debugDisableWebView = true;
    addTearDown(() => HtmlPreviewPage.debugDisableWebView = false);

    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': '画个图'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'entityId': 'e1',
        'fileChanges': {'files': 1, 'additions': 2, 'deletions': 0},
      },
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': 'complete',
        'text': '已生成可视化：\n\n::visualize{"path":"/work/report/图表.html"}',
      },
    ];
    await tester.pumpWidget(
      _host(
        _PreviewApp(rows, {
          'files': 1,
          'additions': 2,
          'deletions': 0,
          'items': [
            {
              'path': 'report/图表.html',
              'additions': 2,
              'deletions': 0,
              'writeCount': 1,
              'toolNames': ['Write'],
              'patches': [
                {
                  'lines': ['+<h1>图表</h1>', '+<p>ok</p>'],
                },
              ],
            },
          ],
        }),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 指令位=卡片（不再是原始指令串）；正文其余段照常渲染。
    final card = find.byKey(
      const ValueKey('visualize-card-/work/report/图表.html'),
    );
    expect(card, findsOneWidget);
    expect(find.textContaining('::visualize'), findsNothing,
        reason: '原始指令串不得再进正文（用户 18074 实锤的代码串）');
    expect(find.text('已生成可视化：'), findsOneWidget);

    // 点卡 → 经 fileChanges 取全文 → 渲染页。
    await tester.tap(card);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(HtmlPreviewPage), findsOneWidget);
    expect(find.text('图表.html'), findsWidgets);
  });

  testWidgets('旅程：新建 html 行进渲染页；编辑 html 与代码文件仍进 diff', (
    tester,
  ) async {
    HtmlPreviewPage.debugDisableWebView = true;
    addTearDown(() => HtmlPreviewPage.debugDisableWebView = false);

    await tester.pumpWidget(
      _host(_PreviewApp(_cardRows(), _changesResult())),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('file-summary-card-2')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 新建 html → 渲染页（WebView 缝关闭时显示不可用文案，页面已进入）。
    await tester.tap(find.byKey(const ValueKey('file-row-report/index.html')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(HtmlPreviewPage), findsOneWidget);
    expect(find.text('index.html'), findsWidgets);
    expect(find.textContaining('网页组件不可用'), findsOneWidget);
    await tester.pageBack();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 编辑过的 html → diff 查看器（协议只送变更行，不渲染半份内容）。
    await tester.tap(find.byKey(const ValueKey('file-row-report/old.html')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DiffViewerPage), findsOneWidget);
    expect(find.byType(HtmlPreviewPage), findsNothing);
    await tester.pageBack();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 代码文件 → diff 查看器（原行为不变）。
    await tester.tap(find.byKey(const ValueKey('file-row-lib/main.dart')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DiffViewerPage), findsOneWidget);
  });
}
