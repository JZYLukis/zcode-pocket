// F5（2026-11-08 拍板⑦收口）：倒计时行内手动「延时」钮已撤——snooze
// 语义是首次有效即永久停止自动解决（不是延时），且可见即发的自动 snooze
// 已停表，手动钮恒为空操作 + 假反馈。本文件锁定：倒计时在场、无手动钮、
// 自动 snooze 只发一次；另钉 #13 的两处收口（到期停 ticker / 幂等账有界）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/interaction_banner.dart';
import 'package:zcode_pocket/transport/conversation.dart';

class _SnoozeApp extends AppState {
  List<Map<String, String>> snoozeCalls = [];
  late final ConversationState convState = ConversationState();

  _SnoozeApp({int? deadlineAt}) {
    convState.applySeed(
      ConversationSeed(
        rows: const [],
        logEpoch: 'e1',
        seq: 0,
        firstRowId: null,
        totalCount: 0,
        snapshot: {
          'title': '贪睡会话',
          'control': {'phase': 'idle'},
          'pendingInteractions': [
            {
              'interactionId': 'ix-1',
              'payload': {
                'kind': 'userInput',
                'prompt': 'Tool AskUserQuestion requires user interaction',
                'toolName': 'AskUserQuestion',
                'questions': [
                  {
                    'question': '继续吗？',
                    'header': '方案',
                    'multiSelect': false,
                    'options': [
                      {'value': 'yes', 'label': '继续'},
                    ],
                  },
                ],
              },
              'autoResolution': {
                'deadlineAt':
                    deadlineAt ??
                    DateTime.now().millisecondsSinceEpoch + 300000,
              },
            },
          ],
        },
      ),
    );
  }

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> snoozeInteractionAutoResolution(
      String sessionId, String interactionId) async {
    snoozeCalls.add({'sessionId': sessionId, 'interactionId': interactionId});
    return null;
  }
}

void main() {
  testWidgets('倒计时在场、手动延时钮已撤、自动 snooze 仅发一次', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _SnoozeApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: app.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 倒计时在场。
    expect(find.textContaining('秒后自动结束'), findsOneWidget);
    // F5（五路审查撤钮）：手动「延时」语义前提错误（snooze=首次有效
    // 永久停止非延时，自动已停表，钮恒为空操作假反馈）——断言钮已撤。
    expect(find.byKey(const ValueKey('snooze-manual')), findsNothing,
        reason: 'F5：手动延时钮已撤（语义前提错误）');
    // 自动 snooze（可见即发）仍在：挂载后应已发一次且只发一次。
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.snoozeCalls, hasLength(1), reason: '自动 snooze（可见即发）幂等只发一次');
    expect(tester.takeException(), isNull);
  });

  testWidgets('倒计时到期后 ticker 停止（#13①：不再每秒 setState 空转）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    // 先清空上一用例残留的树（ticker 在 dispose 里回落计数），再清零。
    await tester.pumpWidget(const SizedBox());
    debugResetAutoResolutionTickers();
    // 先挂一个未来 deadline：ticker 在跑。
    final live = _SnoozeApp();
    await tester.pumpWidget(
      AppStateScope(
        app: live,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: live.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(debugActiveAutoResolutionTickers, 1, reason: '未到期的倒计时在走');

    // 同 interaction 的 deadline 推成过去（服务端已结束）→ 倒计时行退场
    // 且 ticker 同帧停（旧实现每秒 setState 空转到页面销毁）。
    final expired = _SnoozeApp(
      deadlineAt: DateTime.now().millisecondsSinceEpoch - 5000,
    );
    await tester.pumpWidget(
      AppStateScope(
        app: expired,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: expired.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('秒后自动结束'), findsNothing,
        reason: '已过期的倒计时行不渲染');
    expect(debugActiveAutoResolutionTickers, 0,
        reason: '到期后 ticker 必须停（每秒 setState 空转=白耗重建成本）');
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test('snooze 幂等账有界 FIFO（#13②：长会话不无限累积）', () {
    final seen = <String>{};
    expect(markSnoozeOnce(seen, 's1:i1', max: 3), isTrue);
    expect(markSnoozeOnce(seen, 's1:i1', max: 3), isFalse,
        reason: '同键只发一次');
    markSnoozeOnce(seen, 's1:i2', max: 3);
    markSnoozeOnce(seen, 's1:i3', max: 3);
    expect(seen.length, 3);
    markSnoozeOnce(seen, 's1:i4', max: 3);
    expect(seen.length, 3, reason: '超限后容量封顶');
    expect(seen.contains('s1:i1'), isFalse, reason: '按插入序淘汰最旧');
    expect(seen.contains('s1:i4'), isTrue);
  });
}
