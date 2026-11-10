import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _QuickSub implements ConversationSubscription {
  @override
  final String sessionId = 's-quick';
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-quick';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s-quick';
  @override
  Future<void> dispose() async {}

  void seed(List<Map<String, dynamic>> rows) {
    state.applySeed(ConversationSeed(
      rows: rows,
      logEpoch: 'e1',
      seq: rows.length,
      firstRowId: 1,
      totalCount: rows.length,
      snapshot: const {
        'control': {'phase': 'running'},
      },
    ));
  }
}

class _QuickApp extends AppState {
  final sub = _QuickSub();
  @override
  Future<ConversationSubscription> ensureConversation(String id,
      {Object? seedCacheEntry}) async {
    sub.seed(_rows());
    return sub;
  }
}

List<Map<String, dynamic>> _rows() => [
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
          'text': '第 $i 行回答 ' * (i == 5 ? 12 : 3),
        },
      ],
    ];

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

void main() {
  testWidgets('FAB 长按出回合菜单：收起后再次打开显示展开', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppStateScope(
        app: _QuickApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ConversationPage(sessionId: 's-quick', title: '长会话'),
        ),
      ),
    );
    await _pump(tester);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
      of: find.byKey(const ValueKey('chat-scroll')),
      matching: find.byType(Scrollable),
      ),
    );
    scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.5);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);

    await _longPressFab(tester);
    expect(find.byKey(const ValueKey('turn-collapse')), findsOneWidget);
    expect(find.text('收起本回合输出'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('turn-collapse')));
    await tester.pump(const Duration(milliseconds: 200));

    await _longPressFab(tester);
    expect(find.text('展开本回合输出'), findsOneWidget,
        reason: '收起后再次打开应显示展开，且没有误触发一键到底');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
