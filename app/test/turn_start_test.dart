import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _StartSub implements ConversationSubscription {
  _StartSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-start';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s-start';
  @override
  Future<void> dispose() async {}
}

class _StartApp extends AppState {
  _StartApp(this.initialRows, this.olderPages, this.sessionId);
  final List<Map<String, dynamic>> initialRows;
  final List<List<Map<String, dynamic>>> olderPages;
  final String sessionId;
  late final sub = _StartSub(sessionId);
  int loadOlderCalls = 0;

  @override
  Future<ConversationSubscription> ensureConversation(String id) async {
    if (!sub.state.ready) {
      final fullHistory = olderPages.isEmpty;
      sub.state.applySeed(
        ConversationSeed(
          rows: initialRows,
          logEpoch: 'e1',
          seq: initialRows.length,
          firstRowId: fullHistory
              ? (initialRows.first['rowId'] as num?)?.toInt()
              : 1,
          totalCount: fullHistory ? initialRows.length : 500,
          snapshot: const {
            'title': '回合定位',
            'control': {'phase': 'running'},
          },
        ),
      );
    }
    return sub;
  }

  @override
  Future<void> loadOlder(String sessionId) async {
    loadOlderCalls += 1;
    if (olderPages.isEmpty) {
      sub.state.prependOlderRows(const [], null, hasMore: false);
      return;
    }
    final page = olderPages.removeAt(0);
    sub.state.prependOlderRows(page, null, hasMore: olderPages.isNotEmpty);
  }
}

List<Map<String, dynamic>> _loadedTurns() => [
  for (var i = 0; i < 6; i++) ...[
    {
      'rowId': i * 3 + 1,
      'kind': 'turnHeader',
      'state': i == 5 ? 'running' : 'completedSuccess',
    },
    {'rowId': i * 3 + 2, 'kind': 'userInput', 'text': '问 $i'},
    {
      'rowId': i * 3 + 3,
      'kind': 'assistantText',
      'state': i == 5 ? 'streaming' : 'success',
      'text': '第 $i 行回答 ' * (i == 5 ? 18 : 4),
    },
  ],
];

ScrollableState _scrollable(WidgetTester tester) => tester.state(
  find.descendant(
    of: find.byKey(const ValueKey('chat-scroll')),
    matching: find.byType(Scrollable),
  ),
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _longPressFab(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(const ValueKey('jump-bottom'))),
  );
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 500));
}

Widget _host(_StartApp app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(sessionId: app.sessionId, title: '回合定位'),
  ),
);

void main() {
  testWidgets('回到本回合开始：真实 FAB 菜单定位最新用户问题且不粘底', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _StartApp(_loadedTurns(), [], 's-start-loaded');
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    final scroll = _scrollable(tester);
    scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.5);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(
      find.byKey(const ValueKey('chat-scroll')),
      const Offset(0, 80),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);

    await _longPressFab(tester);
    expect(find.byKey(const ValueKey('turn-start')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('turn-start')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final target = find.byKey(const ValueKey('row-17'));
    expect(target, findsOneWidget, reason: '最新回合用户问题必须已挂载');
    final listTop = tester
        .getRect(find.byKey(const ValueKey('chat-scroll')))
        .top;
    expect(
      tester.getTopLeft(target).dy,
      closeTo(listTop, 1.0),
      reason:
          '目标应位于视口顶部；pixels=${scroll.position.pixels} '
          'min=${scroll.position.minScrollExtent} max=${scroll.position.maxScrollExtent} '
          'target=${tester.getRect(target)}',
    );
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);
    expect(app.loadOlderCalls, 0, reason: '目标已在窗口时不得额外拉取历史');

    app.sub.state.applyFrame({
      'fromSeq': 18,
      'toSeq': 19,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'row.appended',
            'row': {
              'rowId': 19,
              'kind': 'assistantText',
              'state': 'streaming',
              'text': '定位后的新输出 ' * 8,
            },
          },
        ],
      },
    }, onGap: () => fail('不应 gap'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(target).dy, closeTo(listTop, 1.0));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('长回合目标不在窗口：先逐页加载再定位，不错跳 guided 输入', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _StartApp(
      [
        for (var i = 0; i < 8; i++)
          {
            'rowId': 200 + i,
            'kind': 'assistantText',
            'state': 'streaming',
            'text': '长回合尾部输出 $i ' * 120,
          },
      ],
      [
        [
          {
            'rowId': 100,
            'kind': 'userInput',
            'text': 'guided 追问，不是回合开始',
            'guided': true,
          },
        ],
        [
          {'rowId': 90, 'kind': 'turnHeader', 'state': 'running'},
          {'rowId': 91, 'kind': 'userInput', 'text': '本回合最初的问题'},
        ],
      ],
      's-start-paged',
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    final scroll = _scrollable(tester);
    scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.5);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(
      find.byKey(const ValueKey('chat-scroll')),
      const Offset(0, 80),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);

    await _longPressFab(tester);
    expect(find.byKey(const ValueKey('turn-start')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('turn-start')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(app.loadOlderCalls, greaterThanOrEqualTo(2));
    expect(find.text('本回合最初的问题'), findsOneWidget);
    final target = find.byKey(const ValueKey('row-91'));
    final listTop = tester
        .getRect(find.byKey(const ValueKey('chat-scroll')))
        .top;
    expect(
      tester.getTopLeft(target).dy,
      closeTo(listTop + 8, 1.0),
      reason: '目标是全会话首条消息时保留既有 8dp 顶部留白',
    );
    final guided = find.text('guided 追问，不是回合开始');
    if (tester.any(guided)) {
      expect(
        tester.getTopLeft(guided).dy,
        isNot(closeTo(listTop + 8, 1.0)),
        reason: 'guided 追问即使在缓存区被挂载，也不能成为定位目标',
      );
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
