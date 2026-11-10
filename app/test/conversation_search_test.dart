import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/conversation_search.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

class _SearchSub implements ConversationSubscription {
  _SearchSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-search';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s-search';
  @override
  Future<void> dispose() async {}
}

class _SearchApp extends AppState {
  _SearchApp(
    this.initialRows,
    this.olderPages,
    this.sessionId, {
    this.conversationPhase = 'completed',
  });
  final List<Map<String, dynamic>> initialRows;
  final List<List<Map<String, dynamic>>> olderPages;
  final String sessionId;
  final String conversationPhase;
  Completer<void>? olderGate;
  Object? olderError;
  late final sub = _SearchSub(sessionId);
  int loadOlderCalls = 0;

  @override
  Future<ConversationSubscription> ensureConversation(String id,
      {Object? seedCacheEntry}) async {
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
          snapshot: {
            'title': '会话搜索',
            'control': {'phase': conversationPhase},
          },
        ),
      );
    }
    return sub;
  }

  @override
  Future<void> loadOlder(String sessionId) async {
    loadOlderCalls++;
    await olderGate?.future;
    if (olderError != null) throw olderError!;
    if (olderPages.isEmpty) {
      sub.state.prependOlderRows(const [], null, hasMore: false);
      return;
    }
    final page = olderPages.removeAt(0);
    sub.state.prependOlderRows(page, null, hasMore: olderPages.isNotEmpty);
  }
}

Widget _host(_SearchApp app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(sessionId: app.sessionId, title: '会话搜索'),
  ),
);

Future<void> _pump(WidgetTester tester, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _conversation({
  String toolOutput = 'terminal needle',
}) => [
  {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
  {'rowId': 2, 'kind': 'userInput', 'text': 'needle'},
  {
    'rowId': 3,
    'kind': 'toolCall',
    'toolName': 'Bash',
    'status': 'success',
    'input': {'command': 'echo ok'},
    'output': {'text': toolOutput},
  },
  {'rowId': 4, 'kind': 'assistantText', 'text': 'final needle'},
];

void main() {
  tearDown(L10n.resetForTest);

  testWidgets('顶栏真实搜索：上一处/下一处循环且关闭不回底', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(_conversation(), [], 's-search-cycle');
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'needle',
    );
    await _pump(tester);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conversation-search-next')));
    await _pump(tester, 8);
    expect(find.text('2/3'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('conversation-search-previous')),
    );
    await _pump(tester, 8);
    expect(find.text('1/3'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('conversation-search-previous')),
    );
    await _pump(tester, 8);
    expect(find.text('3/3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
    await _pump(tester, 5);
    expect(find.byKey(const ValueKey('conversation-search-bar')), findsNothing);
    final turn = find.byKey(const ValueKey('turn-h1'));
    expect(turn, findsOneWidget);
    final listRect = tester.getRect(find.byKey(const ValueKey('chat-scroll')));
    expect(tester.getRect(turn).top, greaterThanOrEqualTo(listRect.top - 1));
    expect(tester.getRect(turn).top, lessThan(listRect.bottom));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);
  });

  testWidgets('工具命中临时展开详情，关闭后恢复原折叠态', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(_conversation(), [], 's-search-tool');
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    expect(find.text('terminal needle'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'terminal needle',
    );
    await _pump(tester);
    expect(find.text('1/1'), findsOneWidget);
    final output = find.descendant(
      of: find.byKey(const ValueKey('turn-h1')),
      matching: find.text('terminal needle'),
    );
    expect(output, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
    await _pump(tester, 5);
    expect(output, findsNothing);
    expect(find.text('final needle'), findsOneWidget);
  });

  testWidgets('匹配只在未加载历史：自动补拉后定位真实目标', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(
      [
        {'rowId': 100, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 101, 'kind': 'userInput', 'text': 'current question'},
        {'rowId': 102, 'kind': 'assistantText', 'text': 'current answer ' * 80},
      ],
      [
        [
          {'rowId': 90, 'kind': 'turnHeader', 'state': 'completedSuccess'},
          {'rowId': 91, 'kind': 'userInput', 'text': 'ancient needle'},
          {'rowId': 92, 'kind': 'assistantText', 'text': 'older answer'},
        ],
      ],
      's-search-history',
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'ancient needle',
    );
    await _pump(tester, 25);

    expect(app.loadOlderCalls, 1);
    expect(find.text('1/1'), findsOneWidget);
    final target = find.byKey(const ValueKey('row-91'));
    expect(target, findsOneWidget);
    expect(
      find.descendant(of: target, matching: find.text('ancient needle')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);
  });

  testWidgets('长提问命中临时展开，关闭及再次搜索不丢手动展开状态', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 跨测试静态滚动记忆会在 50/300ms 校正窗口内拽回旧视口（本测试
    // 的展开交互恰落在窗口内）——先清（同 S11 游览场景先例）。
    ConversationPage.debugResetScrollMemory();
    final longText = '${'上下文行\n' * 12}tail needle';
    final app = _SearchApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': longText},
      ],
      [],
      's-search-long-user',
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    expect(find.byKey(const ValueKey('fold-expand')), findsOneWidget);

    Future<void> search() async {
      await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-input')),
        'tail needle',
      );
      await _pump(tester);
    }

    await search();
    expect(find.byKey(const ValueKey('fold-expand')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
    await _pump(tester, 5);
    expect(find.byKey(const ValueKey('fold-expand')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fold-expand')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fold-collapse')), findsOneWidget);
    await search();
    expect(find.byKey(const ValueKey('fold-collapse')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
    await _pump(tester, 5);
    expect(find.byKey(const ValueKey('fold-collapse')), findsOneWidget);
  });

  testWidgets('部分回合补齐历史后更新锚点，目标仍在视口', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(
      [
        {'rowId': 102, 'kind': 'assistantText', 'text': 'partial needle'},
      ],
      [
        [
          {'rowId': 100, 'kind': 'turnHeader', 'state': 'completedSuccess'},
          {'rowId': 101, 'kind': 'userInput', 'text': 'question'},
          {'rowId': 99, 'kind': 'assistantText', 'text': 'earlier work'},
        ],
      ],
      's-search-partial-turn',
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'partial needle',
    );
    await _pump(tester, 25);
    final turn = find.byKey(const ValueKey('turn-h100'));
    final target = find.descendant(
      of: turn,
      matching: find.text('partial needle'),
    );
    expect(target, findsOneWidget);
    final listRect = tester.getRect(find.byKey(const ValueKey('chat-scroll')));
    final targetRect = tester.getRect(target);
    expect(targetRect.bottom, greaterThan(listRect.top));
    expect(targetRect.top, lessThan(listRect.bottom));
  });

  testWidgets('长工具输出按 occurrence 滚动，下一处在同一行内也移动', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final output = [
      for (var i = 0; i < 80; i++)
        'line-$i${i == 60 || i == 70 ? ' target-needle' : ''}',
    ].join('\n');
    final app = _SearchApp(
      _conversation(toolOutput: output),
      [],
      's-search-long-output',
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'target-needle',
    );
    await _pump(tester);
    expect(find.text('1/2'), findsOneWidget);
    ScrollPosition outputPosition() {
      final states = tester.stateList<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('turn-h1')),
          matching: find.byType(Scrollable),
        ),
      );
      return states
          .map((s) => s.position)
          .firstWhere((p) => p.maxScrollExtent > 0);
    }

    final first = outputPosition().pixels;
    expect(first, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('conversation-search-next')));
    await _pump(tester, 10);
    expect(find.text('2/2'), findsOneWidget);
    expect(outputPosition().pixels, greaterThan(first));
  });

  testWidgets('子代理合并卡的工具命中在卡内显示实际上下文', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(
      [
        {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 2, 'kind': 'userInput', 'text': 'question'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Agent',
          'toolCallId': 'call-1',
          'status': 'success',
          'input': {'prompt': 'hidden agent needle'},
          'output': {'text': 'done'},
        },
        {
          'rowId': 4,
          'kind': 'subagent',
          'parentToolCallId': 'call-1',
          'summaryText': 'child',
          'status': 'success',
        },
        {'rowId': 5, 'kind': 'assistantText', 'text': 'answer'},
      ],
      [],
      's-search-agent-pair',
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'hidden agent needle',
    );
    await _pump(tester);
    final card = find.byKey(const ValueKey('turn-h1'));
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('hidden agent needle'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('运行中未补拉历史时明确仅已加载范围，不冒充完整无结果', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(
      _conversation(),
      [
        [
          {'rowId': 90, 'kind': 'userInput', 'text': 'older needle'},
        ],
      ],
      's-search-running',
      conversationPhase: 'running',
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'not-in-window',
    );
    await _pump(tester);
    expect(app.loadOlderCalls, 0);
    expect(find.text('当前仅搜索已加载内容，运行结束后自动补查更早消息'), findsOneWidget);
    expect(find.text('没有匹配结果'), findsNothing);
  });

  testWidgets('旧查询的历史错误不得污染已清空的新查询', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(_conversation(), [
      [
        {'rowId': 90, 'kind': 'userInput', 'text': 'older needle'},
      ],
    ], 's-search-stale-error');
    app.olderGate = Completer<void>();
    app.olderError = StateError('offline');
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'older',
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      '',
    );
    app.olderGate!.complete();
    await _pump(tester);
    expect(
      find.byKey(const ValueKey('conversation-search-retry')),
      findsNothing,
    );
  });

  testWidgets('英文深色 320dp/1.3：搜索栏完整且无溢出', (tester) async {
    L10n.setTestLocale('en-US');
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = TextEditingController(text: 'needle');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    final matches = buildConversationSearchMatches(
      buildChatItems(_conversation()),
      'needle',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: ConversationSearchBar(
              controller: controller,
              focusNode: focus,
              query: 'needle',
              matches: matches,
              activeIndex: 0,
              loading: false,
              truncated: true,
              error: null,
              onChanged: (_) {},
              onPrevious: () {},
              onNext: () {},
              onClose: () {},
              onRetry: () {},
            ),
          ),
        ),
      ),
    );
    await _pump(tester, 3);
    expect(find.text('Search messages and tools'), findsOneWidget);
    expect(
      find.text(
        'Searched the latest 1200 rows; earlier content is not included',
      ),
      findsOneWidget,
    );
    expect(find.text('1/3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 18077 验收#11（Bug H）：提问内容同享词级高亮——搜索激活时提问
  // 气泡走 user-search-highlight 渲染路径（修前仅 assistant 有高亮，
  // 提问命中只有行级定位效果）。
  testWidgets('提问气泡搜索高亮：命中词走词级高亮渲染', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _SearchApp(_conversation(), [], 's-search-userhl');
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    // 未激活搜索：普通 Text 渲染。
    expect(
      find.byKey(const ValueKey('user-search-highlight')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('conversation-search-entry')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('conversation-search-input')),
      'needle',
    );
    await _pump(tester);
    expect(
      find.byKey(const ValueKey('user-search-highlight')),
      findsAtLeastNWidgets(1),
      reason: '搜索激活后提问气泡必须走词级高亮 Text.rich（Bug H）',
    );
    // 关闭搜索恢复普通渲染（高亮不残留）。
    await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
    await _pump(tester, 6);
    expect(
      find.byKey(const ValueKey('user-search-highlight')),
      findsNothing,
      reason: '关闭搜索后恢复原渲染',
    );
  });
}
