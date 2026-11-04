// 滚动状态机对齐批 C 红绿（2026-10-26，官方 timelineScrollAnchor 语义）：
// ①落点裁决——非程序化窗口的滚动序列结束落点距底>48 → 解除跟随（原仅
// 手指拖拽可解除，惯性滑出被粘底 tick 拉回）；②滚动记忆——离开存位置
// 与贴底态，重进还原（非贴底不粘底）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows);
  final List<Map<String, dynamic>> rows;

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
          'title': '滚动状态机',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

/// 开源审查 A1-P2/A3-P1 两阶段红绿夹具：缓存预渲（本地读，先落地）+
/// 可控延迟的活订阅（ensureConversation 过 gate，模拟冷会话网络唤醒）。
/// A3 实证：此前测试环境的订阅路径从不落地（_RowsApp 无 stack 恒抛），
/// 「预渲先还原 → live ready 无条件 _stickToBottom=true+_snapToBottom
/// 跳底覆盖还原」的顺序甲竞态零覆盖——温重开阅读位置必丢。
class _PreviewLiveApp extends AppState {
  _PreviewLiveApp(this.rows, {String sessionId = 's1', this.liveSeqDelta = 0})
    : sessionId = sessionId;
  final List<Map<String, dynamic>> rows;
  final String sessionId;

  /// live 快照比缓存多的 seq 数（>0=离开期间有新输出）。
  final int liveSeqDelta;

  /// 订阅闸门：不 complete 则 ensureConversation 不返回（预渲必先落地）。
  final gate = Completer<void>();
  late final sub = _PreviewSub(sessionId);

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
          'title': '滚动状态机',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );

  @override
  Future<ConversationSubscription> ensureConversation(String id) async {
    await gate.future;
    if (!sub.state.ready) {
      sub.state.applySeed(
        ConversationSeed(
          rows: rows,
          logEpoch: 'e1',
          seq: rows.length + liveSeqDelta,
          firstRowId: 1,
          totalCount: rows.length,
          snapshot: const {
            'title': '滚动状态机',
            'control': {'phase': 'idle'},
          },
        ),
      );
    }
    return sub;
  }
}

class _PreviewSub implements ConversationSubscription {
  _PreviewSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-preview';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

Widget _host(AppState app, {String sessionId = 's1'}) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: ConversationPage(sessionId: sessionId, title: '滚动状态机'),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _longRows() => [
      // 轮结构（纯正文行不进投影——buildChatItems 语义，夹具需带
      // turnHeader+userInput 成轮）。
      for (var i = 0; i < 15; i++) ...[
        {
          'rowId': i * 3 + 1,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
        },
        {'rowId': i * 3 + 2, 'kind': 'userInput', 'text': '问 $i'},
        {
          'rowId': i * 3 + 3,
          'kind': 'assistantText',
          'state': 'success',
          'text': '长会话第 $i 行 ' * 4,
        },
      ],
    ];

ScrollableState _scrollable(WidgetTester tester) => tester.state(
      find.descendant(
      of: find.byKey(const ValueKey('chat-scroll')),
      matching: find.byType(Scrollable),
      ),
    );

void main() {
  testWidgets('落点裁决：滚动序列落点离底>48 → 解除跟随出 FAB（原仅拖拽可解）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(_RowsApp(_longRows())));
    await _pump(tester);

    // 粘底态初始无 FAB。
    expect(find.byKey(const ValueKey('jump-bottom')), findsNothing);

    // 模拟"用户滚动序列结束落点离底"：直接操作 position（不经生产代码
    // 的 _markProgrammatic 窗口）→ 产生的 ScrollEnd 参与落点裁决。
    final scroll = _scrollable(tester);
    scroll.position
        .jumpTo((scroll.position.maxScrollExtent * 0.5).clamp(0.0, double.infinity));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('jump-bottom')),
      findsOneWidget,
      reason: '落点距底>48 须解除跟随（对齐批 C 核心；修复前：惯性/外部'
          '滚动落点不解除，被粘底 tick 拉回）',
    );
  });

  testWidgets('滚动记忆：中部离开→重进还原位置且不粘底', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _RowsApp(_longRows());

    // 第一次进入：滚到中部后退出（pop → dispose 存记忆）。
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final scroll = _scrollable(tester);
    final mid = scroll.position.maxScrollExtent * 0.5;
    scroll.position.jumpTo(mid);
    await tester.pump(const Duration(milliseconds: 100));
    // 落点裁决已解除粘底（上例语义）→ FAB 在场=非贴底态。
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold())); // 触发 dispose
    await tester.pump(const Duration(milliseconds: 100));

    // 第二次进入同会话：还原中部位置（FAB 在场=非贴底），非回底。
    await tester.pumpWidget(_host(_RowsApp(_longRows())));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400)); // 两次校正到期
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget,
        reason: '记忆非贴底 → 重进不粘底（官方 wasPinnedToBottom=false 语义）');
    final restored = _scrollable(tester).position.pixels;
    expect(
      restored,
      inExclusiveRange(50, _scrollable(tester).position.maxScrollExtent - 200),
      reason: '位置还原在中部而非顶部/底部',
    );
  });

  // 以下两用例用独立 sessionId 避开 static _scrollMemory 的跨用例残留。
  Future<void> _primeMemory(WidgetTester tester, String sid) async {
    final app = _PreviewLiveApp(_longRows(), sessionId: sid);
    await tester.pumpWidget(_host(app, sessionId: sid));
    app.gate.complete(); // 第一遍无记忆：预渲+订阅都到 → 默认贴底。
    await _pump(tester);
    final scroll = _scrollable(tester);
    scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.5);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold())); // dispose 存记忆
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('开源审查 A1-P2/A3-P1：缓存预渲先还原，live ready 后跳底不得覆盖阅读位置', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _primeMemory(tester, 's-plv');

    // 第二遍（温重开）：订阅闸门关——预渲必先落地并还原记忆。
    final app2 = _PreviewLiveApp(_longRows(), sessionId: 's-plv');
    await tester.pumpWidget(_host(app2, sessionId: 's-plv'));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget,
        reason: '预渲路径已还原非贴底记忆');

    // live ready（冷会话网络唤醒后到）：无新输出（seq 相同）——还原的
    // 阅读位置必须保持。修复前：_stickToBottom=true 无条件翻回+第二次
    // _snapToBottom 跳底+1.2s 粘底跟随覆盖，温重开必回列表底部。
    //（另一层：strip 退场使消息列表 Element 重建、position 复位 0——
    // 修复同时重放记忆校正把阅读位置接回。）
    app2.gate.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget,
        reason: 'live ready 不得覆盖已还原的非贴底记忆（A1-P2 顺序甲）');
    expect(
      _scrollable(tester).position.pixels,
      inExclusiveRange(
        50,
        _scrollable(tester).position.maxScrollExtent - 200,
      ),
      reason: '阅读位置保持在中部（未被跳底覆盖）',
    );
  });

  testWidgets('开源审查 A1-P2 对照：live 快照确有新输出（seq 前进）时仍贴底', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _primeMemory(tester, 's-plv2');

    // 第二遍：live seq 比缓存前进（离开期间会话有新输出）→ 贴底看新。
    final app2 = _PreviewLiveApp(_longRows(), sessionId: 's-plv2', liveSeqDelta: 5);
    await tester.pumpWidget(_host(app2, sessionId: 's-plv2'));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget,
        reason: '预渲先还原（尚不知有无新输出）');
    app2.gate.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('jump-bottom')), findsNothing,
        reason: '确有新输出 → live ready 贴底（回底语义不回归）');
  });
}
