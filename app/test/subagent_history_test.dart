import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _SlowSub implements ConversationSubscription {
  @override
  final String sessionId = 'child-1';
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-child';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/child-1';
  @override
  Future<void> dispose() async {}

  void seed() {
    state.applySeed(ConversationSeed(
      rows: const [
        {'rowId': 1, 'kind': 'assistantText', 'text': '子代理历史内容'},
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

class _SlowApp extends AppState {
  final sub = _SlowSub();

  /// 测试缝：非空时 ensureConversation 抛该错误（lineage-invalid 映射用例）。
  Object? overrideEnsureError;
  @override
  bool get loaded => true;
  @override
  Future<ConversationSubscription> ensureConversation(String sessionId) {
    return Future.delayed(const Duration(milliseconds: 100), () {
      final err = overrideEnsureError;
      if (err != null) throw err;
      sub.seed();
      return sub;
    });
  }
}

void main() {
  testWidgets('只读子代理历史：超时阈值放宽，冷恢复完成不误报失败', (tester) async {
    await tester.pumpWidget(
      AppStateScope(
        app: _SlowApp(),
        child: const MaterialApp(
          home: ConversationPage(
            sessionId: 'child-1',
            title: '子代理',
            readOnly: true,
            subscribeTimeout: Duration(milliseconds: 50),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 75));
    expect(find.textContaining('订阅会话失败'), findsNothing,
        reason: '只读冷恢复超过普通 60s 档时仍应等待，而不是先报错');

    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('订阅会话失败'), findsNothing);
    expect(find.text('子代理历史内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('lineage-invalid 人话化：子目录子会话不再怼协议原文（18075 验收 C）', (tester) async {
    final app = _SlowApp();
    app.overrideEnsureError = StateError(
      'ChannelRpcError: Failed to resume persisted session child-1: '
      'project.session-lineage-invalid (fault.subscribe.resumeFailed)',
    );
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(
          home: ConversationPage(
            sessionId: 'child-1',
            title: '子代理',
            readOnly: true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('归属其他项目目录'), findsOneWidget,
        reason: '应显示人话出路文案');
    expect(find.textContaining('session-lineage-invalid'), findsNothing,
        reason: '协议原文不得直接怼给用户');
    expect(find.textContaining('fault.subscribe'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('普通会话仍按普通超时档报错', (tester) async {
    await tester.pumpWidget(
      AppStateScope(
        app: _SlowApp(),
        child: const MaterialApp(
          home: ConversationPage(
            sessionId: 'child-1',
            title: '普通会话',
            subscribeTimeout: Duration(milliseconds: 50),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 75));
    expect(find.textContaining('订阅会话失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
