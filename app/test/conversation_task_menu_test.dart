import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _MenuSub implements ConversationSubscription {
  @override
  final String sessionId = 't1';
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-t1';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/t1';
  @override
  Future<void> dispose() async {}

  void seed() {
    state.applySeed(ConversationSeed(
      rows: const [
        {'rowId': 1, 'kind': 'assistantText', 'text': '示例内容'},
      ],
      logEpoch: 'e1',
      seq: 1,
      firstRowId: 1,
      totalCount: 1,
      snapshot: const {
        'control': {'phase': 'completedSuccess'},
      },
    ));
  }
}

class _MenuApp extends AppState {
  final sub = _MenuSub();
  bool pinned = false;
  int pinCalls = 0;
  bool? lastPinned;

  @override
  bool get loaded => true;
  @override
  Future<ConversationSubscription> ensureConversation(String sessionId,
      {Object? seedCacheEntry}) async {
    sub.seed();
    return sub;
  }

  @override
  List<Map<String, dynamic>> get workspaceTasks => [
        {
          'taskId': 't1',
          'title': '示例任务',
          'pinned': pinned,
          'workspacePath': 'D:/示例项目',
        },
      ];

  @override
  Future<dynamic> setTaskPinned(String taskId, bool value) async {
    pinCalls++;
    lastPinned = value;
    pinned = value;
    notifyListeners();
  }
}

void main() {
  testWidgets('会话右上菜单：置顶/取消置顶按当前状态显示并执行', (tester) async {
    final app = _MenuApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(
          home: ConversationPage(sessionId: 't1', title: '示例任务'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    Future<void> openMenu() async {
      await tester.tap(find.byKey(const ValueKey('task-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await openMenu();
    expect(find.text('置顶'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await tester.pump();
    expect(app.pinCalls, 1);
    expect(app.lastPinned, isTrue);

    await openMenu();
    expect(find.text('取消置顶'), findsOneWidget);
  });
}
