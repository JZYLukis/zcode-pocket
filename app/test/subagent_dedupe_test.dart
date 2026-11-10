// 子代理双渲染去重回归（2026-10-25 用户实锤问题③）：Agent/Task 工具行
// 与 subagent 行是同一 spawn 的两条 wire 行——官方 conversationAssistant
// WorkItems.ts:203-269 按 parentToolCallId 配对后只渲染一个块。本文件锁：
// 配对（精确+历史兜底）/未配对不丢/运行态标题琥珀、完成态回落灰。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async {
    // 只给父会话缓存：下钻子会话走空缓存→标题回落 widget.title
    // （断言的正是这条兜底路径）。
    if (id != 's1') return null;
    return SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: {
          'title': '子代理去重',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ConversationPage(sessionId: 's1', title: '子代理去重'),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, dynamic> _agentTool(int rowId, String callId, String desc) => {
      'rowId': rowId,
      'kind': 'toolCall',
      'toolCallId': callId,
      'toolName': 'Agent',
      'status': 'running',
      'inputText': '{"description":"$desc"}',
    };

Map<String, dynamic> _subagentRow(
  int rowId,
  String summary,
  String status, {
  String? parentToolCallId,
  String? childSessionId,
}) =>
    {
      'rowId': rowId,
      'kind': 'subagent',
      // ignore: use_null_aware_elements —— 显式判空更贴夹具可读性。
      if (parentToolCallId != null) 'parentToolCallId': parentToolCallId,
      if (childSessionId != null) 'childSessionId': childSessionId,
      'subagentType': 'general-purpose',
      'status': status,
      'summaryText': summary,
    };

void main() {
  testWidgets('parentToolCallId 精确配对：工具行撤销，只渲染一张卡',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '去勘察工作区'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-1', '勘察①新任务工作区归属'),
      _subagentRow(4, '勘察①新任务工作区归属', 'running',
          parentToolCallId: 'tc-1'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);

    // 卡（smart_toy 图标）恰好一张。
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    // 2026-11-05 反馈①：合并卡=「子智能体 · 类型 · summary」三段式
    //（官方 ToolSummaryRow 对位）——前缀恰一份；工具行 preview 若残留
    // 会是第二份（重复根源）。
    expect(find.textContaining('general-purpose · '), findsOneWidget,
        reason: '1.0.1 验收②：机器人图标已表意，标题去「子智能体」前缀');
    expect(find.textContaining('子智能体 ·'), findsNothing,
        reason: '验收②：前缀已去');
    expect(find.textContaining('general-purpose · 勘察①新任务工作区归属'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('合并卡下钻：无 summary 时页面标题带子代理类型（对抗审查 H1 锁）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    // summaryText 为空=下钻标题退「子智能体 <type>」兜底的常用形态
    // （迁移笔误曾丢掉 $type，AppBar 显示尾随空格的「子智能体 」）。
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '去勘察'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      _agentTool(3, 'tc-1', '勘察'),
      _subagentRow(4, '', 'success',
          parentToolCallId: 'tc-1', childSessionId: 'child-s1'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);

    await tester.tap(find.byIcon(Icons.smart_toy_outlined));
    await _pump(tester);
    // 2026-11-05 反馈①：下钻页 AppBar 标题=类型名（官方
    // sidePaneTabPresentation L127 优先用 subagentType；合并卡本体在
    // 路由下层仍在树中，故限定 AppBar 内断言）。
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('general-purpose'),
      ),
      findsOneWidget,
    );
    expect(find.text('子智能体 '), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史兜底：无 parentToolCallId 且双方各剩唯一→仍去重',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '查一下'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-1', '检索用法'),
      _subagentRow(4, '检索用法', 'success'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    expect(find.textContaining('general-purpose ·'), findsOneWidget,
        reason: '验收②形态恰一份；工具行残留会是第二份');
  });

  testWidgets('未配对的 Agent 工具行保留（不丢可见性）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '两件事'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-1', '任务甲'),
      _agentTool(4, 'tc-2', '任务乙'),
      _subagentRow(5, '任务甲', 'running', parentToolCallId: 'tc-1'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    // tc-1 配对撤销；tc-2 未配对→工具行保留（宁可重复不丢行）。
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget,
        reason: '配对的 subagent 卡');
    expect(find.textContaining('子智能体 · 任务乙'), findsOneWidget,
        reason: '未配对的 Agent 工具行照常渲染');
  });

  testWidgets('运行中标题琥珀、完成后回落灰（随 logo 同档）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    Color runningColorOf(BuildContext c) =>
        Theme.of(c).extension<AppThemeSpec>()!.colors.running;
    late Color runningToken;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '并发两个'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-1', '运行中的那个'),
      _subagentRow(4, '运行中的那个', 'running', parentToolCallId: 'tc-1'),
      _agentTool(5, 'tc-2', '完成的那个'),
      _subagentRow(6, '完成的那个', 'success', parentToolCallId: 'tc-2'),
    ]);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) {
              runningToken = runningColorOf(context);
              return const ConversationPage(
                  sessionId: 's1', title: '子代理去重');
            },
          ),
        ),
      ),
    );
    await _pump(tester);

    final runningTitle =
        tester.widget<Text>(find.textContaining('运行中的那个')).style!.color;
    final doneTitle =
        tester.widget<Text>(find.textContaining('完成的那个')).style!.color;
    expect(runningTitle, runningToken,
        reason: '运行中标题=running 琥珀（与 logo 同档，用户 2026-10-25）');
    expect(doneTitle, isNot(runningToken), reason: '完成后回落灰');
  });

  testWidgets('H12 批②：失败态可读（红标题+「· 失败」后缀）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    Color destructiveOf(BuildContext c) =>
        Theme.of(c).extension<AppThemeSpec>()!.colors.destructive;
    late Color destructiveToken;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '去勘察'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedInterrupted'},
      _agentTool(3, 'tc-1', '会失败的勘察'),
      {
        ..._subagentRow(4, '会失败的勘察', 'failed', parentToolCallId: 'tc-1'),
      },
    ]);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) {
              destructiveToken = destructiveOf(context);
              return const ConversationPage(sessionId: 's1', title: '子代理去重');
            },
          ),
        ),
      ),
    );
    await _pump(tester);

    expect(find.textContaining('会失败的勘察 · 失败'), findsOneWidget,
        reason: '失败必须在合并卡上有可读信号（灰卡无字=失败不可见）');
    final title =
        tester.widget<Text>(find.textContaining('会失败的勘察 · 失败')).style!;
    expect(title.color, destructiveToken, reason: '失败标题=destructive 红');
  });

  testWidgets('H12 批②：工具行 error 而子代理无状态→失败仍可见（并集）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑任务'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedInterrupted'},
      {..._agentTool(3, 'tc-1', '工具侧失败'), 'status': 'error'},
      _subagentRow(4, '工具侧失败', '', parentToolCallId: 'tc-1'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    expect(find.textContaining('工具侧失败 · 失败'), findsOneWidget,
        reason: 'Agent 工具行 error 时子代理即便无状态也须示失败');
  });

  testWidgets('H12 批②：guided 跨段配对——段一 Agent×段二 subagent 单卡且在工具行位置',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '去办两步'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-1', '跨段子任务'),
      // guided 追问切段：段二只含 subagent 行（旧行为=两段各渲染一次）。
      {'rowId': 5, 'kind': 'userInput', 'text': '追问进展'},
      _subagentRow(6, '跨段子任务', 'running', parentToolCallId: 'tc-1'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);

    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget,
        reason: '跨段配对后只出一张合并卡（旧行为段一工具行+段二卡双渲染）');
    expect(find.textContaining('general-purpose ·'), findsOneWidget,
        reason: '验收②形态：类型 · 摘要恰一份');
    // 合并卡渲染在 Agent 工具行原位置（官方 agentToolCall 项）——即
    // 位于 guided 追问气泡之前。
    final cardTop = tester.getTopLeft(
      find.ancestor(
        of: find.byIcon(Icons.smart_toy_outlined),
        matching: find.byType(Container),
      ),
    );
    final guidedTop = tester.getTopLeft(find.text('追问进展'));
    expect(cardTop.dy, lessThan(guidedTop.dy),
        reason: '合并卡在工具行原位置（guided 追问之前）');
  });

  testWidgets('H12 批②：-1 哨兵（rowId 缺失）不参与配对——双渲染保底',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    Map<String, dynamic> noId(int callSeq, String desc) => {
          'kind': 'toolCall',
          'toolCallId': 'tc-x$callSeq',
          'toolName': 'Agent',
          'status': 'running',
          'inputText': '{"description":"$desc"}',
        };
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '异常数据'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      noId(1, '无行号甲'),
      noId(2, '无行号乙'),
      _subagentRow(5, '无行号甲', 'running', parentToolCallId: 'tc-x1'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    expect(find.textContaining('子智能体 · 无行号甲'), findsOneWidget,
        reason: 'rowId 缺失的工具行不配对（不误吞）');
    expect(find.textContaining('子智能体 · 无行号乙'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget,
        reason: 'subagent 行因父行无法配对而独立保留（fail-open）');
  });

  // ---- 文本双射兜底（2026-11-06 真机「阶段2」会话实锤）----
  // 3.16.3 桌面 live 路径：并发 4 子代理的 subagent 行 parentToolCallId
  // 未与工具行 toolCallId 对上 → 8 行双渲染（4 工具行 + 4 卡）。
  // 冷读 transcript-hydration 恒填 part.callID（重进自愈），故本兜底
  // 主战场=live。锁：描述↔摘要双射命中时收敛回 4 卡。

  testWidgets('文本兜底：并发4无parentToolCallId且描述摘要双射→4卡0工具行',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '并行审查'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-a', '视觉审查精选与备航 A'),
      _agentTool(4, 'tc-b', '视觉交叉备航与驻留 B'),
      _agentTool(5, 'tc-c', '视觉审查父母置顶'),
      _agentTool(6, 'tc-d', '独立审查内容迁移与隔离'),
      _subagentRow(7, '视觉审查精选与备航 A', 'success'),
      _subagentRow(8, '视觉交叉备航与驻留 B', 'success'),
      _subagentRow(9, '视觉审查父母置顶', 'success'),
      _subagentRow(10, '独立审查内容迁移与隔离', 'running'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    // 修复前红：4 工具行 + 4 卡双渲染（真机截图形态）。
    expect(find.byIcon(Icons.smart_toy_outlined), findsNWidgets(4),
        reason: '四张合并卡');
    expect(find.textContaining('子智能体 ·'), findsNothing,
        reason: '文本双射全中→工具行零残留');
    expect(tester.takeException(), isNull);
  });

  testWidgets('文本兜底：parentToolCallId 有值但孤儿（真机失败形态）也能收敛',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '并行'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-a', '任务甲'),
      _agentTool(4, 'tc-b', '任务乙'),
      // parentToolCallId 指向不存在的调用（id 对不上但文本能对上）。
      _subagentRow(5, '任务乙', 'success', parentToolCallId: 'orphan-999'),
      _subagentRow(6, '任务甲', 'running', parentToolCallId: 'orphan-998'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    expect(find.byIcon(Icons.smart_toy_outlined), findsNWidgets(2),
        reason: '孤儿 id 落文本兜底配对');
    expect(find.textContaining('子智能体 ·'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文本兜底：同描述歧义→不配，保持双渲染（宁重复不张冠李戴）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '同名两路'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-a', '完全相同的任务'),
      _agentTool(4, 'tc-b', '完全相同的任务'),
      _subagentRow(5, '完全相同的任务', 'running'),
      _subagentRow(6, '完全相同的任务', 'success'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    // 双侧键均重复=歧义：两条工具行 + 两张卡全保留。
    expect(find.byIcon(Icons.smart_toy_outlined), findsNWidgets(2));
    expect(find.textContaining('子智能体 ·'), findsNWidgets(2),
        reason: '歧义不配——误配比重复更糟');
    expect(tester.takeException(), isNull);
  });

  testWidgets('文本兜底：部分命中只收敛命中对，未命中的保持双渲染',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '三路'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      _agentTool(3, 'tc-a', '任务甲'),
      _agentTool(4, 'tc-b', '任务乙'),
      _subagentRow(5, '任务甲', 'success'),
      // 任务乙的子代理摘要是结果概述≠spawn 描述——键对不上。
      _subagentRow(6, '乙已完成并产出报告', 'success'),
    ]);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    expect(find.byIcon(Icons.smart_toy_outlined), findsNWidgets(2),
        reason: '甲=合并卡；乙的 subagent 独立成卡');
    expect(find.textContaining('子智能体 · 任务乙'), findsOneWidget,
        reason: '乙工具行无匹配→保留（fail-open）');
    expect(tester.takeException(), isNull);
  });
}
