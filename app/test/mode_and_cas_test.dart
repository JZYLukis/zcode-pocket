import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

Widget _host(AppState app, {Widget? child}) => AppStateScope(
      app: app,
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('CAS 收敛重试决策（nextCasRetryRevision，官方 sendHostCasCommandV4 同款 refs zcodeV4HostCommand.ts:132-166）', () {
    test('stale 带 revisionAtDecision → 返回服务端最新 revision 供重试', () {
      expect(
        nextCasRetryRevision(
          {'status': 'stale', 'revisionAtDecision': 42},
          attempts: 1,
        ),
        42,
      );
    });

    test('accepted/duplicate/noop → 停止（成功态不重试）', () {
      for (final s in ['accepted', 'duplicate', 'noop']) {
        expect(
          nextCasRetryRevision(
            {'status': s, 'revisionAtDecision': 42},
            attempts: 1,
          ),
          isNull,
          reason: s,
        );
      }
    });

    test('rejected/failed/非 Map → 停止（交给调用方报错）', () {
      expect(
        nextCasRetryRevision({'status': 'rejected'}, attempts: 1),
        isNull,
      );
      expect(nextCasRetryRevision('boom', attempts: 1), isNull);
    });

    test('stale 缺 revisionAtDecision → 停止（无法收敛，不能盲重试）', () {
      expect(
        nextCasRetryRevision({'status': 'stale'}, attempts: 1),
        isNull,
      );
    });

    test('尝试上限 4：第 3 次仍 stale 可再试，第 4 次不再', () {
      expect(
        nextCasRetryRevision(
          {'status': 'stale', 'revisionAtDecision': 9},
          attempts: 3,
        ),
        9,
      );
      expect(
        nextCasRetryRevision(
          {'status': 'stale', 'revisionAtDecision': 9},
          attempts: 4,
        ),
        isNull,
      );
    });
  });

  group('模式选择落地决策（resolveModePickAction）', () {
    test('已有会话 → 立即下发 switchCollaborationMode（官方桌面行为）', () {
      expect(
        resolveModePickAction(sessionId: 's1'),
        ModePickAction.immediate,
      );
    });

    test('新会话草稿 → 挂起随 createSession.config 提交', () {
      expect(
        resolveModePickAction(sessionId: null),
        ModePickAction.pending,
      );
    });
  });

  group('子代理下钻只读视图', () {
    testWidgets('readOnly 隐藏输入区（无发送键/语音键），显示只读条', (
      tester,
    ) async {
      final app = AppState();
      await tester.pumpWidget(
        _host(
          app,
          child: const ConversationPage(
            sessionId: null,
            title: '子智能体',
            readOnly: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('send-button')), findsNothing);
      expect(find.byKey(const ValueKey('voice-input')), findsNothing);
      expect(find.text('子智能体工作记录 · 只读'), findsOneWidget);
    });

    testWidgets('普通会话不受影响：输入区照常（发送键存在）', (tester) async {
      final app = AppState();
      await tester.pumpWidget(
        _host(
          app,
          child: const ConversationPage(sessionId: null, title: '草稿'),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('send-button')), findsOneWidget);
      expect(find.text('子智能体工作记录 · 只读'), findsNothing);
    });
  });
}
