import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _RewindSub implements ConversationSubscription {
  @override
  final String sessionId = 's-rewind';
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-rewind';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s-rewind';
  @override
  Future<void> dispose() async {}

  void seed() {
    state.applySeed(ConversationSeed(
      rows: const [
        {
          'rowId': 1,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'entityId': 'e1',
          'fileChanges': {'files': 1},
          'actions': {'canRewindFiles': true},
        },
        {'rowId': 2, 'kind': 'userInput', 'text': '改一下'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': '已完成'},
      ],
      logEpoch: 'e1',
      seq: 3,
      firstRowId: 1,
      totalCount: 3,
      snapshot: const {
        'control': {'phase': 'completedSuccess'},
      },
    ));
  }
}

class _RewindApp extends AppState {
  final sub = _RewindSub();
  @override
  Future<ConversationSubscription> ensureConversation(String id,
      {Object? seedCacheEntry}) async {
    sub.seed();
    return sub;
  }
}

void main() {
  testWidgets('回滚入口触控区扩大到 44dp，且 tooltip 在场', (tester) async {
    await tester.pumpWidget(
      AppStateScope(
        app: _RewindApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ConversationPage(sessionId: 's-rewind', title: '回滚'),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final key = const ValueKey('早前批次');
    expect(find.byKey(key), findsOneWidget);
    final size = tester.getSize(find.byKey(key));
    expect(size.width, 44);
    expect(size.height, 44);
    expect(find.byTooltip('回滚到本轮前'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
