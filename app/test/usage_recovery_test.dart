// 验收#18 红绿（Bug Q/R）：用量页断网不得永远转圈；网络恢复
// 自动重试。修前：断网时 transport 挂死连 RPC 30s 都不触发（Q），恢复
// 后也不重拉、须退出重进（R）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/usage_page.dart';

/// 挂死通道：hangNext=true 时 call 永不完成（模拟断网 transport 挂死——
/// 连 TimeoutException 都不抛，这正是 Bug Q 的现场形态）。
class _HangingChannel extends ChannelClient {
  _HangingChannel() : super(sendBody: (_) {});
  bool hangNext = false;
  int okCalls = 0;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (hangNext) {
      return Completer<dynamic>().future;
    }
    okCalls++;
    return Future.value(const {});
  }
}

class _HangingBridge implements BridgeSession {
  final _HangingChannel channel = _HangingChannel();
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-usage-recovery';
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

class _RecoveryApp extends AppState {
  final _HangingBridge hangingBridge = _HangingBridge();
  bool onlineOverride = true;
 /// 模拟 relay 掉档（reconnecting）：桥为恢复保留、phase 非 online
 /// ——真实断网形态（反馈#6 同款语义）。
  bool offlinePhase = false;

  @override
  BridgeSession? get bridge => onlineOverride ? hangingBridge : null;

  @override
  LinkPhase get phase => offlinePhase
      ? LinkPhase.reconnecting
      : (onlineOverride ? LinkPhase.online : LinkPhase.offline);
}

Future<void> _pump(WidgetTester tester, [int frames = 15]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('断网挂死：12s 页面级超时进错误态（不再永远转圈）+ 重试按钮', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (call) async => 'Asia/Shanghai',
    );
    final app = _RecoveryApp()..onlineOverride = true;
 // 桥在但所有 usage 调用挂死（Bug Q 现场）。
    app.hangingBridge.channel.hangNext = true;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const UsagePage()),
      ),
    );
    await _pump(tester, 20);

 // 12s 页面级超时后：错误态呈现（默认 tab=个人套餐，文案=网络不佳
 // 人话+重试按钮），不再无限 spinner。
    await tester.pump(const Duration(seconds: 13));
    await _pump(tester, 8);
    expect(find.textContaining('网络不佳'), findsWidgets,
        reason: '挂死 12s 后必须进错误态（Bug Q：修前永远转圈）');
    expect(find.text('重试'), findsWidgets, reason: '错误态出口=重试按钮');
  });

  testWidgets('错误态+网络恢复 online 边沿：自动重拉，不要求退出重进（Bug R）', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (call) async => 'Asia/Shanghai',
    );
    final app = _RecoveryApp()
      ..onlineOverride = true
      ..offlinePhase = true;
    app.hangingBridge.channel.hangNext = true;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const UsagePage()),
      ),
    );
    await _pump(tester, 20);
    await tester.pump(const Duration(seconds: 13));
    await _pump(tester, 8);
    expect(find.textContaining('网络不佳'), findsWidgets);

 // （终审）：后台边沿不 force 双拉的正向锁——paused 下
 // offline→online 不得产生新 RPC（省电红线），回前台后必须重拉。
    final okBeforeEdge = app.hangingBridge.channel.okCalls;
    app.offlinePhase = false;
    app.notifyListeners();
    await _pump(tester, 10);
    expect(app.hangingBridge.channel.okCalls, okBeforeEdge,
        reason: 'paused 状态 offline→online 边沿不得 force 双拉（电量红线）');
    app.offlinePhase = true;
    app.notifyListeners();
    await _pump(tester, 5);

 // 网络恢复：挂死解除 + phase 回 online + app 通知（恢复横幅那次）。
 // N1- 修复后后台边沿不 force 双拉（电量红线）——测试须显式置于
 // 前台 resumed（真机常见路径），否则恢复分支按设计早退。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    app.hangingBridge.channel.hangNext = false;
    app.offlinePhase = false;
    app.notifyListeners();
    await _pump(tester, 25);

    expect(app.hangingBridge.channel.okCalls, greaterThan(0),
        reason: '恢复边沿自动重拉（Bug R：修前须退出重进）');

 // 收尾：挂起请求的 12s 页面级超时 timer 仍在飞——推进到期让 timer
 // 自然完成（否则 tearDown 报 pending timer）。
    await tester.pump(const Duration(seconds: 13));
    await _pump(tester, 4);
  });
}
