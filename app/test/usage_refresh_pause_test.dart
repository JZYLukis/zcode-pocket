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

/// 电量速赢（battery-measure 2026-10-08 静态排查嫌疑②）：
/// 用量页退后台必须暂停 60s 刷新定时器——桥活着时每次刷新都是一次
/// radio 唤醒。修复前红：后台 70s 内仍会发起第二轮 usage-stats 调用。

class _CountingChannel extends ChannelClient {
  _CountingChannel() : super(sendBody: (_) {});
  int calls = 0;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (method.startsWith('get')) calls++;
    return {};
  }
}

class _CountingBridge implements BridgeSession {
  final _CountingChannel counting = _CountingChannel();
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
  ChannelClient get channels => counting;
  @override
  String? get workspaceKey => 'ws-battery';
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

class _BatteryUsageApp extends AppState {
  @override
  final BridgeSession bridge = _CountingBridge();
}

void main() {
  testWidgets('退后台暂停 60s 刷新，回前台恢复', (tester) async {
    // companion/timezone 平台消息在 widget 测试里不回包（卡在通道缓冲），
    // 显式 mock 让 readDeviceTimeZone 完成。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (call) async => 'Asia/Shanghai',
    );
    final app = _BatteryUsageApp();
    final counting = app.bridge.channels as _CountingChannel;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const UsagePage()),
      ),
    );
    // 首载两路调用（entitlement + cp + app）；平台消息往返需要多个
    // 事件循环节拍，分小步泵（游览 S27 同款节奏）。
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final atForeground = counting.calls;
    expect(atForeground, greaterThanOrEqualTo(3));

    // 后台 70s：修复前会再来一轮 60s 刷新；修复后不得有任何新调用。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 70));
    expect(counting.calls, atForeground, reason: '后台不得再发 usage-stats 调用');

    // 回前台：定时器重建（SWR 用真实时钟，fake 测试里 TTL 未过期，
    // 60s 内回前台按设计命中缓存不重拉——断言不产生重复调用）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(counting.calls, atForeground, reason: 'TTL 内回前台命中缓存，不得重复拉取');

    // 再次退后台：重挂的定时器同样要被暂停（防"只暂停一次"回归）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 70));
    expect(counting.calls, atForeground, reason: '第二个后台窗口同样静默');
  });
}
