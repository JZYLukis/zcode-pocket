import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/interaction_banner.dart';
import 'package:zcode_pocket/ui/voice_input_sheet.dart'
    show debugVoiceRecognitionAvailable;
import 'package:zcode_pocket/transport/conversation.dart';

/// 立即失败的 createSession（A1：草稿态首条消息失败零提示）。
class _SendTestBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-send-test';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _ImmediateFailAppState extends AppState {
  // 断网排队批（2026-10-29）：无桥发送会改道入队——这些用例的语义是
  // 「已连接但发送失败/在途」，补桥保持原路径。
  @override
  BridgeSession? get bridge => _SendTestBridge();

  @override
  Future<String> createSession(
    String? firstText, {
    Map<String, dynamic>? config,
  }) async {
    throw StateError('测试注入：createSession 失败');
  }
}

/// 受控失败的 createSession（A2/A3：发送在途窗口可控）。
class _GatedFailAppState extends AppState {
  // 断网排队批（2026-10-29）：无桥发送会改道入队——这些用例的语义是
  // 「已连接但发送失败/在途」，补桥保持原路径。
  @override
  BridgeSession? get bridge => _SendTestBridge();

  _GatedFailAppState(this.gate);
  final Completer<void> gate;

  @override
  Future<String> createSession(
    String? firstText, {
    Map<String, dynamic>? config,
  }) async {
    await gate.future;
    throw StateError('测试注入：createSession 失败');
  }
}

/// resolveInteraction 按注入错误失败（A5）。
class _ResolveThrowAppState extends AppState {
  // 断网排队批（2026-10-29）：无桥发送会改道入队——这些用例的语义是
  // 「已连接但发送失败/在途」，补桥保持原路径。
  @override
  BridgeSession? get bridge => _SendTestBridge();

  _ResolveThrowAppState(this.error);
  final Object error;

  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    throw error;
  }
}

Widget _host(AppState app, {Widget? child}) => AppStateScope(
      app: app,
      child: MaterialApp(home: Scaffold(body: child)),
    );

ConversationState _stateWithInteraction() => ConversationState()
  ..snapshot = {
    'pendingInteractions': [
      {
        'interactionId': 'i1',
        'payload': {
          'kind': 'permission',
          'toolName': 'Bash',
          'detail': {'command': 'echo hi'},
          'options': [
            {'optionId': 'o1', 'label': 'Allow', 'kind': 'allow'},
            {'optionId': 'o2', 'label': 'Deny', 'kind': 'deny'},
          ],
        },
      },
    ],
  };


ConversationState _stateWithPlanInteraction() => ConversationState()
  ..snapshot = {
    'pendingInteractions': [
      {
        'interactionId': 'ip1',
        'payload': {
          'kind': 'permission',
          'toolName': 'ExitPlanMode',
          'detail': {'command': 'plan approval'},
          'options': [
            {'optionId': 'po1', 'label': 'Approve', 'kind': 'allow'},
            {'optionId': 'po2', 'label': 'Keep planning', 'kind': 'deny'},
          ],
        },
      },
    ],
  };

void main() {
  group('A1/A2/A3 草稿态发送路径', () {
    testWidgets('A1 createSession 失败：错误横幅可见（原门禁吞掉）', (tester) async {
      final app = _ImmediateFailAppState();
      await tester.pumpWidget(
        _host(app, child: const ConversationPage(sessionId: null, title: '草稿')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '第一条消息',
      );
      await tester.pump(); // 发送键随 controller 重建（enterText 后必 pump）
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      await tester.pump();
      // 草稿态无订阅（_sub 为 null）——原横幅门禁 `_sub?.state != null`
      // 使错误零出口；修复后横幅必须渲染发送失败文案。
      expect(find.textContaining('发送失败'), findsOneWidget);
      // 正文回填（输入框空闲分支，既有行为保留）
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-input')))
            .controller!
            .text,
        '第一条消息',
      );
    });

    testWidgets('A2 等待期新输入不被覆盖+暂存条恢复', (tester) async {
      final gate = Completer<void>();
      final app = _GatedFailAppState(gate);
      await tester.pumpWidget(
        _host(app, child: const ConversationPage(sessionId: null, title: '草稿')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '原始消息',
      );
      await tester.pump(); // 发送键随 controller 重建（enterText 后必 pump）
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      // 发送在途（失败未到）：暂存条不存在
      expect(find.byKey(const ValueKey('restore-unsent')), findsNothing);
      // 等待期输入新内容（附件等待最长 5 分钟的场景）
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '新输入',
      );
      await tester.pump();
      gate.completeError(StateError('boom'));
      await tester.pump();
      await tester.pump();
      final field =
          tester.widget<TextField>(find.byKey(const ValueKey('chat-input')));
      // 关键断言：新输入不被原文覆盖（原实现无条件回填）
      expect(field.controller!.text, '新输入');
      // 原文暂存条出现
      expect(find.byKey(const ValueKey('restore-unsent')), findsOneWidget);
      expect(find.textContaining('已暂存'), findsOneWidget);
      // 恢复：插入光标处，两段内容都保留
      await tester.tap(find.byKey(const ValueKey('restore-unsent')));
      await tester.pump();
      final restored =
          tester.widget<TextField>(find.byKey(const ValueKey('chat-input')));
      expect(restored.controller!.text.contains('原始消息'), isTrue);
      expect(restored.controller!.text.contains('新输入'), isTrue);
      expect(find.byKey(const ValueKey('restore-unsent')), findsNothing);
    });

    testWidgets('A2 输入框空闲时仍直接回填（原行为保留）', (tester) async {
      final app = _ImmediateFailAppState();
      await tester.pumpWidget(
        _host(app, child: const ConversationPage(sessionId: null, title: '草稿')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '唯一消息',
      );
      await tester.pump(); // 发送键随 controller 重建（enterText 后必 pump）
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-input')))
            .controller!
            .text,
        '唯一消息',
      );
      expect(find.byKey(const ValueKey('restore-unsent')), findsNothing);
    });

    testWidgets('A3 发送在途：发送键禁用（原可点但静默无反应）', (tester) async {
      final gate = Completer<void>(); // 永不完成：停在发送在途
      final app = _GatedFailAppState(gate);
      await tester.pumpWidget(
        _host(app, child: const ConversationPage(sessionId: null, title: '草稿')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '第一条',
      );
      await tester.pump(); // 发送键随 controller 重建（enterText 后必 pump）
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      // 等待期再输入后点发送——原实现按钮可点但 onSend 静默 return；
      // 修复后发送中禁用。
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '第二条',
      );
      await tester.pump();
      final btn = tester.widget<IconButton>(
        find.byKey(const ValueKey('send-button')),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('A5 审批应答错误吞并（alreadyResolved 精确匹配）', () {
    testWidgets('特征测试（钉老行为）：alreadyResolved 仍静默', (tester) async {
      final app = _ResolveThrowAppState(
        StateError('Bad State: interaction alreadyResolved'),
      );
      await tester.pumpWidget(
        _host(app, child: InteractionBanner(state: _stateWithInteraction(), sessionId: 's1')),
      );
      await tester.tap(find.text('允许'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('恰好含 already 的其它错误：必须提示（原被吞）', (tester) async {
      final app = _ResolveThrowAppState(
        StateError('Bad State: file already opened elsewhere'),
      );
      await tester.pumpWidget(
        _host(app, child: InteractionBanner(state: _stateWithInteraction(), sessionId: 's1')),
      );
      await tester.tap(find.text('允许'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('应答发送失败'), findsOneWidget);
    });

    testWidgets('普通网络错误：必须提示（既有行为）', (tester) async {
      final app = _ResolveThrowAppState(StateError('network down'));
      await tester.pumpWidget(
        _host(app, child: InteractionBanner(state: _stateWithInteraction(), sessionId: 's1')),
      );
      await tester.tap(find.text('允许'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('语音键退役+状态点回归（2026-10-22 用户拍板）', () {
    setUp(() => debugVoiceRecognitionAvailable = true);
    tearDown(() => debugVoiceRecognitionAvailable = null);
    testWidgets('语音键消失、状态点在输入栏、长按发送键唤起语音面板', (tester) async {
      final app = AppState();
      await tester.pumpWidget(
        _host(app, child: const ConversationPage(sessionId: null, title: '草稿')),
      );
      expect(find.byKey(const ValueKey('voice-input')), findsNothing);
      expect(find.byKey(const ValueKey('status-dot')), findsOneWidget);
      // 验收回填（2026-10-22 可发现性）：空闲且无草稿时发送键图标=麦克风
      // （点按直达语音）；输入文字后变回发送箭头。
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      await tester.enterText(find.byType(TextField).first, '你好');
      await tester.pump();
      expect(find.byIcon(Icons.mic_rounded), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      // 清空草稿回到麦克风；点麦克风直接唤起语音面板。
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BottomSheet), findsOneWidget);
      // 长按发送键（含草稿为空时）= 语音输入（拍板语义不变）。
    });

    testWidgets('长按发送键唤起语音面板（拍板语义保留）', (tester) async {
      final app = AppState();
      await tester.pumpWidget(
        _host(app, child: const ConversationPage(sessionId: null, title: '草稿')),
      );
      await tester.longPress(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('点发送即收起输入法（2026-10-23 拍板：键盘不再常驻挡屏）', (tester) async {
      final app = _ImmediateFailAppState();
      await tester.pumpWidget(
        _host(app, child: const ConversationPage(sessionId: null, title: '草稿')),
      );
      final input = find.byKey(const ValueKey('chat-input'));
      await tester.enterText(input, '第一条消息');
      await tester.pump();
      final inputNode = tester.widget<TextField>(input).focusNode!;
      expect(inputNode.hasFocus, true, reason: '前置：输入中键盘聚焦');
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      expect(
        inputNode.hasFocus,
        false,
        reason: '发送后应失焦收起输入法（失败横幅路径同样收起）',
      );
      // 失败回填后草稿文本仍在（A2 语义不回归）。
      await tester.pump();
      expect(find.textContaining('第一条消息'), findsWidgets,
          reason: '输入框回填即可（≥1）；宽匹配防"多渲染一份"回归由'
              '专属用例钉数量');
    });
  });

  group('18077 验收#6（Bug B）：计划批准选项中文化', () {
    testWidgets('Approve/Keep planning 映射中文（原样透传英文为 bug）', (tester) async {
      final app = _ResolveThrowAppState(StateError('unused'));
      await tester.pumpWidget(
        _host(app, child: InteractionBanner(state: _stateWithPlanInteraction(), sessionId: 's1')),
      );
      await tester.pump();
      expect(find.text('批准'), findsOneWidget, reason: 'Approve 应映射「批准」');
      expect(find.text('继续规划'), findsOneWidget, reason: 'Keep planning 应映射「继续规划」');
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Keep planning'), findsNothing);
    });
  });
}
