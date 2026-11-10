// 欠账盘点 B5 接线修复红绿（2026-11-08）：通知深链「定位到相关消息？」
// 浮层在真实时序下永不弹——task_center 消费时已把 pendingOpenTask 清空，
// 会话页的全局 getter pendingDeepLinkTarget 依赖它 → 恒 null。修复=atMs
// 随导航参数 deepLinkAtMs 透传（waitForWorkspace 同款模式）。
// 红=不带参数（旧时序形态）浮层不出现；绿=带参数出现。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

/// 游览 _TourConvSub 同款（ConversationSubscription 构造私有 → implements）。
class _Sub implements ConversationSubscription {
  _Sub(this.sid);
  final String sid;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-$sid';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sid';
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeepLinkApp extends AppState {
  final sub = _Sub('s1');
  final int anchorMs;

  _DeepLinkApp(this.anchorMs);

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<ConversationSubscription> ensureConversation(String sessionId,
      {Object? seedCacheEntry}) async {
    return sub;
  }
}

void _seedAndNotify(_Sub sub, int anchorMs) {
  sub.state.applySeed(
    ConversationSeed(
      rows: [
        {'rowId': 1, 'kind': 'userInput', 'text': '更早的问题', 'createdAt': anchorMs - 60000},
        {
          'rowId': 2,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'createdAt': anchorMs - 1000,
        },
        {'rowId': 3, 'kind': 'assistantText', 'text': '通知对应的回答', 'createdAt': anchorMs},
      ],
      logEpoch: 'e1',
      seq: 3,
      firstRowId: 1,
      totalCount: 3,
      snapshot: const {
        'title': '深链会话',
        'control': {'phase': 'idle'},
      },
    ),
  );
  sub.state.notifyListeners();
}

Widget _host(AppState app, {int? deepLinkAtMs}) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: ConversationPage(
          sessionId: 's1',
          title: '深链会话',
          deepLinkAtMs: deepLinkAtMs,
        ),
      ),
    );

void main() {
  testWidgets('深链浮层：atMs 参数透传 → 「定位到相关消息」出现并可点', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final anchor = DateTime.now().millisecondsSinceEpoch - 5000;
    final app = _DeepLinkApp(anchor)
      // 真实时序：task_center 已消费并清空 pendingOpenTask，只剩 atMs。
      ..pendingDeepLinkAt = anchor;
    await tester.pumpWidget(_host(app, deepLinkAtMs: anchor));
    _seedAndNotify(app.sub, anchor);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(const ValueKey('deeplink-prompt')),
      findsOneWidget,
      reason: 'B5 修复：参数透传后浮层出现（旧时序恒不出现）',
    );

    // #3 高：点「定位」必须把 center 锚到目标行所属**顶层条目**——
    // 命中行是回合内 assistantText（没有独立 'row-*' 键），旧实现直接
    // 拼 'row-3' → center 落空回退 0（整列跳到最老），滚动记忆被写坏。
    ConversationPage.debugLastJumpAnchorKey = null;
    await tester.tap(find.text('定位'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      ConversationPage.debugLastJumpAnchorKey,
      'turn-h2',
      reason: '行号→回合条目键映射（turnHeader rowId=2）',
    );
    expect(
      ConversationPage.debugScrollMemoryAnchor('s1'),
      'turn-h2',
      reason: '滚动记忆存的是真实条目键（旧实现写入 row-3 坏键）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('深链提示排程一次性（#15）：尝试后不再逐帧排 postFrame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final anchor = DateTime.now().millisecondsSinceEpoch - 5000;
    final app = _DeepLinkApp(anchor);
    await tester.pumpWidget(_host(app));
    _seedAndNotify(app.sub, anchor);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final first = ConversationPage.debugDeepLinkScheduleCount;
    expect(first, greaterThan(0), reason: '就绪后尝试过一次');
    // 后续状态通知照常驱动 _doRender，但「已尝试」标记必须阻止再排程。
    for (var i = 0; i < 5; i++) {
      app.sub.state.notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      ConversationPage.debugDeepLinkScheduleCount,
      first,
      reason: '已尝试后（即使无目标）不得每次重建都排 postFrame',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('深链浮层：无参数（旧接线形态）→ 不出现（红侧锁定）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final anchor = DateTime.now().millisecondsSinceEpoch - 5000;
    final app = _DeepLinkApp(anchor)..pendingDeepLinkAt = anchor;
    // 不传 deepLinkAtMs 且 pendingOpenTask 已被清空（真实旧时序）。
    await tester.pumpWidget(_host(app));
    _seedAndNotify(app.sub, anchor);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(const ValueKey('deeplink-prompt')),
      findsNothing,
      reason: '旧接线形态全局 getter 恒 null——正是 B5 症状（本例锁根因）',
    );
    expect(tester.takeException(), isNull);
  });
}
