// 批4 用户反馈回填（2026-10-23，回填律）：
// ① 深色停止键黑底白标（浅色红底白标不动）
// ②a 流式执行中从入参推 ±N（官方 fileSummaries.ts 同款时序）
//    + file_diffs 复数形态合计（官方 readFileDiffDisplays 双形态）
// ②b 思考条流式摘要两行（一行信息量不足）
// ③ 输入栏顺序对齐桌面：状态圈（空心）→模型药丸→发送
// 注入路径同 ui_v4_visual_tour ：AppState 覆写 readSessionCache
// 预渲 rows（缓存会话不建活流，widget 测试离线稳定）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/markdown_view.dart';
import 'package:zcode_pocket/ui/motion.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows, this.controlPhase);
  final List<Map<String, dynamic>> rows;
  final String controlPhase;

  @override
  LinkPhase get phase => LinkPhase.online;

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
          'title': '批4回填',
          'control': {'phase': controlPhase},
          'usage': {
            'contextWindow': {'usedTokens': 12000, 'maxTokens': 1000000},
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app, Widget page, {Brightness b = Brightness.light}) =>
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme: b == Brightness.dark
            ? buildAppTheme(Brightness.dark)
            : buildAppTheme(),
        home: page,
      ),
    );

/// 有界泵：页面含无限动画（扫光/脉冲），pumpAndSettle 不可用。
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // Dart 源里 \\n=两字符（反斜杠+n），运行时 jsonDecode 后成真换行。
  final editRunningInput =
      '{"file_path":"a.dart","old_string":"l1\\nl2","new_string":"l1\\nl2\\nl3\\nl4"}';

  testWidgets('②a 流式执行中：Edit 行从入参推 +4 -2（先行值）', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '改一下'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Edit',
          'status': 'running',
          'inputText': editRunningInput,
        },
      ],
      'running',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '批4回填')));
    await _pump(tester);
    // 运行轮默认展开（批1 回合状态机），工具行常驻可见。
    expect(find.textContaining('执行中'), findsWidgets,
        reason: '工具行状态标签可能因多行工具同时渲染出现多份，≥1 即可');
    expect(find.textContaining('+4'), findsOneWidget,
        reason: '流式期应从 input 参数推新增行数（官方 fileSummaries.ts）');
    expect(find.textContaining('-2'), findsOneWidget,
        reason: '流式期应从 old_string 推删除行数');
  });

  testWidgets('②a Write 流式：content 行数推 +3（无删除）', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '新建'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Write',
          'status': 'running',
          'inputText': '{"path":"b.dart","content":"a\\nb\\nc"}',
        },
      ],
      'running',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '批4回填')));
    await _pump(tester);
    expect(find.textContaining('+3'), findsOneWidget);
  });

  testWidgets('②a 非编辑类工具流式：不显示计数（Bash 无 ±N）', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '跑测试'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Bash',
          'status': 'running',
          'inputText': 'npm test --integration',
        },
      ],
      'running',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '批4回填')));
    await _pump(tester);
    expect(find.textContaining(RegExp(r'[+-]\d')), findsNothing,
        reason: '非编辑/写入工具不应出现 ±N 占位');
  });

  testWidgets('②a 完成态 file_diffs 复数形态：多文件合计 +7 -1', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '多文件改'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Edit',
          'status': 'success',
          'inputText': '{}',
          'output': {
            'display': {
              'kind': 'file_diffs',
              'files': [
                {'filePath': 'a.dart', 'additions': 5, 'deletions': 1},
                {'filePath': 'b.dart', 'additions': 2, 'deletions': 0},
              ],
            },
          },
        },
      ],
      'idle',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '批4回填')));
    await _pump(tester);
    // 完成轮默认收起——展开回合见工具行。
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await _pump(tester);
    expect(find.textContaining('+7'), findsOneWidget,
        reason: 'file_diffs 复数形态应聚合各文件 additions');
    expect(find.textContaining('-1'), findsOneWidget);
  });

  testWidgets('②b 思考条流式摘要两行', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '想想'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'reasoning',
          'state': 'streaming',
          'text': '先看配置加载路径再排查渲染管线',
        },
      ],
      'running',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '批4回填')));
    await _pump(tester);
    final bars = tester
        .widgetList<ShimmerText>(find.byType(ShimmerText))
        .where((w) => w.text.contains('正在思考'))
        .toList();
    expect(bars, isNotEmpty, reason: '流式思考条应存在扫光摘要');
    expect(bars.first.maxLines, 2,
        reason: '批4 反馈②：摘要一行信息量不足，折叠态最多两行');
    // 对抗审查 （2026-10-24 补—— 批声称回填但从未落库，调用点
    // 曾两次丢失）：minLines:2 必须在位（定高两行防 1↔2 行切换跳动）。
    expect(bars.first.minLines, 2,
        reason: '流式期定高两行占位——此断言丢失曾是「还跳」实锤根因');
  });

  testWidgets('②b 思考条完成态一行高（用户拍板 2026-10-24 二轮：流式两行'
      '→完成一行，收缩由 AnimatedSize 平滑）', (tester) async {
    // 流式期 minLines:2 定高两行防跳动；完成态 FixedLinesText(lines:1)
    // 一行高（两行占位在收起的流式内容族中突兀）——短/长句占位恒等。
    Future<double> heightOf(String text, String state) async {
      final app = _RowsApp(
        [
          {'rowId': 1, 'kind': 'userInput', 'text': '想想'},
          {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
          {
            'rowId': 3,
            'kind': 'reasoning',
            'state': state,
            'text': text,
            if (state != 'streaming') 'durationMs': 5000,
          },
        ],
        'running',
      );
      await tester.pumpWidget(_host(
          app, const ConversationPage(sessionId: 's1', title: '批4回填')));
      await _pump(tester);
      return tester.getSize(find.byType(FixedLinesText).first).height;
    }

    final short = await heightOf('短', 'complete');
    final long = await heightOf('很长'.padRight(400, '长'), 'complete');
    expect(short, closeTo(long, 0.5),
        reason: '完成态定高一行——短句/长句占位恒等');
  });

  testWidgets('① 停止键：深色黑底白标+描边；浅色红底白标不动', (tester) async {
    final rows = [
      {'rowId': 1, 'kind': 'userInput', 'text': '跑'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
    ];
    Color bgOf(WidgetTester t) {
      final btn = t.widget<IconButton>(find.byKey(const ValueKey('stop-button')));
      return btn.style!.backgroundColor!.resolve({})!;
    }

    // 深色：黑底（background）+白标（brand）。
    await tester.pumpWidget(_host(
        _RowsApp(List.of(rows), 'running'),
        const ConversationPage(sessionId: 's1', title: '批4回填'),
        b: Brightness.dark));
    await _pump(tester);
    expect(find.byKey(const ValueKey('stop-button')), findsOneWidget);
    expect(bgOf(tester), AppThemeSpec.dark.colors.background,
        reason: '批4 反馈①：深色停止键改黑底（红底扎眼）');
    final darkBtn =
        tester.widget<IconButton>(find.byKey(const ValueKey('stop-button')));
    expect(darkBtn.style!.foregroundColor!.resolve({}),
        AppThemeSpec.dark.colors.brand);
    expect(darkBtn.style!.side, isNotNull, reason: '深色停止键带描边（浮起感）');

    // 浅色：红底白标保持官方系不动。
    await tester.pumpWidget(_host(
        _RowsApp(List.of(rows), 'running'),
        const ConversationPage(sessionId: 's1', title: '批4回填')));
    await _pump(tester);
    expect(bgOf(tester), AppThemeSpec.light.colors.destructive,
        reason: '浅色停止键保持红底（回归红线）');
  });

  testWidgets('③ 输入栏：状态圈在模型药丸左侧且为空心圈', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      ],
      'idle',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '批4回填')));
    await _pump(tester);
    final dot = tester.getTopLeft(find.byKey(const ValueKey('status-dot')));
    final pill = tester.getTopLeft(find.byKey(const ValueKey('model-switch')));
    expect(dot.dx < pill.dx, isTrue,
        reason: '批4 反馈③：对齐桌面输入栏——状态圈在模型药丸左侧');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('status-dot')),
        matching: find.byKey(const ValueKey('context-usage-ring')),
      ),
      findsOneWidget,
      reason: '状态指示为上下文占用进度环（2026-10-26 对齐桌面 '
          'context.tsx：底环 25%+进度弧 70%；原空心圈退役）',
    );
  });

  testWidgets('④ 本地路径点击无任何响应（绿色渲染保留）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: MarkdownView(
            data: '改了 [theme.dart](G:\\Demo App\\core\\theme.dart)',
          ),
        ),
      ),
    );
    await tester.pump();
    // 本地路径渲染为绿色链接文本（绿色=用户认可保留），点击不做任何
    // 响应（批4 反馈④ 用户拍板：协议无文件内容通道+复制路径无用）。
    // 注：点击到达处理函数并提前返回已在开发期插桩验证（widget 测试
    // 光栅化字体下 span 命中区与绘制区错位，回调级断言不稳定，故只
    // 断言可见行为=无 SnackBar）。
    final rp = tester.renderObject<RenderParagraph>(
        find.textContaining('theme.dart', findRichText: true));
    final text = rp.text.toPlainText();
    final i = text.indexOf('theme.dart');
    final b = rp
        .getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 'theme.dart'.length),
        )
        .first
        .toRect();
    // 覆盖整个链接区域逐点尝试（测试字体命中盒偏移的兜底）。
    for (var dx = 0.0; dx <= b.width; dx += 7) {
      await tester
          .tapAt(rp.localToGlobal(b.topLeft) + Offset(dx, b.height / 2));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
