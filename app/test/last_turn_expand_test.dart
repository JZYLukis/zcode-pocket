// 问题②（2026-10-25 用户拍板）回归：①会话末轮默认展开（冻结重进/
// 回 app 整页收起只剩一句正文+「加载更早消息」观感不可用——桌面最近
// 内容常态可见）；②缓存预渲期「回到底部」悬浮球也要有（live state
// 未就绪时上滑翻读后无箭头回底——真机实锤主场景）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows, {this.ctrlPhase = 'idle'});
  final List<Map<String, dynamic>> rows;
  final String ctrlPhase;

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
          'title': '末轮展开',
          'control': {'phase': ctrlPhase},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ConversationPage(sessionId: 's1', title: '末轮展开'),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _twoTurns() => [
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 3, 'kind': 'userInput', 'text': '第一问'},
      {
        'rowId': 4,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': 'success',
        'inputText': '{"file_path":"first-turn-file.dart"}',
        'output': {'text': 'ok'},
      },
      {'rowId': 5, 'kind': 'assistantText', 'state': 'complete', 'text': '第一答'},
      {'rowId': 7, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 8, 'kind': 'userInput', 'text': '第二问'},
      {
        'rowId': 9,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': 'success',
        'inputText': '{"file_path":"last-turn-file.dart"}',
        'output': {'text': 'ok'},
      },
      {
        'rowId': 10,
        'kind': 'assistantText',
        'state': 'complete',
        'text': '第二答',
      },
    ];

void main() {
  testWidgets('完成后默认收起（含末轮），点开才见步骤——2026-10-26 澄清语义',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(_host(_RowsApp(_twoTurns())));
    await _pump(tester);

    // 运行完后全部收起只剩最后回复（含末轮——末轮默认展开已拨回）：
    // 两轮工具行均不可见（收起态只有状态条+外置正文）。
    expect(
      find.textContaining('last-turn-file.dart'),
      findsNothing,
      reason: '末轮完成默认收起（2026-10-26 用户澄清：运行中展开、完成后收起）',
    );
    expect(
      find.textContaining('first-turn-file.dart'),
      findsNothing,
      reason: '历史轮完成态默认收起（不变）',
    );
    expect(find.text('第二答'), findsOneWidget, reason: '收起态外置正文可见');
    expect(tester.takeException(), isNull);

    // 点开末轮 → 步骤可见（手动展开）。
    await tester.tap(find.text('已处理').last);
    await _pump(tester);
    expect(
      find.textContaining('last-turn-file.dart'),
      findsWidgets,
      reason: '点开后末轮步骤可见',
    );
  });

  testWidgets('窗口运行中（含缓存预渲期）末轮不收起——phaseRunning 承接',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    // 用户澄清的原报障场景（2026-10-26）：后台冻结很久回 app，窗口仍在
    // 运行，缓存里末轮 header 停在旧完成态——按"运行中展开"呈现，不得
    // 整页收起。
    await tester.pumpWidget(_host(_RowsApp(_twoTurns(), ctrlPhase: 'running')));
    await _pump(tester);
    expect(
      find.textContaining('last-turn-file.dart'),
      findsWidgets,
      reason: '窗口运行中→末轮按运行中呈现（缓存 header 旧完成态也承接）',
    );
    expect(
      find.textContaining('first-turn-file.dart'),
      findsNothing,
      reason: '历史轮不受影响',
    );
  });

  testWidgets('缓存预渲期上滑后「回到底部」悬浮球在场', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    // 收起语义（2026-10-26）下轮内正文随轮收起——旧夹具用末轮内 30 行
    // 正文撑高度，末轮收起后全藏（max=0 不可滚）。改用 12 个小轮次填充
    // （收起态也占高），测试焦点（缓存期悬浮球）不随轮密度漂移。
    final rows = [
      ..._twoTurns(),
      for (var i = 0; i < 12; i++) ...[
        {'rowId': 100 + i * 3, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 101 + i * 3, 'kind': 'userInput', 'text': '追问第 $i 轮'},
        {
          'rowId': 102 + i * 3,
          'kind': 'assistantText',
          'state': 'complete',
          'text': '历史回答第 $i 轮：' * 4,
        },
      ],
    ];
    await tester.pumpWidget(_host(_RowsApp(rows)));
    await _pump(tester);

    // 无 live state（_RowsApp 只有缓存）——列表为缓存预渲。上滑翻读
    // 历史后悬浮球必须出现（修复前 state==null 直接不渲染箭头）。
    await tester.drag(
      find.byKey(const ValueKey('chat-scroll')),
      const Offset(0, 400),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('jump-bottom')),
      findsOneWidget,
      reason: '缓存预渲期上滑后须有一键到底（问题②真机实锤场景）',
    );
    // 点悬浮球回底并恢复粘底。
    await tester.tap(find.byKey(const ValueKey('jump-bottom')));
    await _pump(tester);
    expect(find.byKey(const ValueKey('jump-bottom')), findsNothing,
        reason: '回底粘住后箭头隐藏');
  });
}
