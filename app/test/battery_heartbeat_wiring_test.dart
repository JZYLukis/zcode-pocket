import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

/// 电量专项接线回归：
/// - 早前批次（2026-10-29）：退后台放宽心跳覆盖全部分支；
/// - 优化批 #16/#17（2026-10-31）：退后台档位表重排——
///   ①审批提醒开（保活分支）：30s 慢档心跳 + 驻留会话明细订阅
///     （suspendConversationSubscriptions——桌面活跃会话持续推流式帧
/// 是保活档后台耗电主因，真机 660mAh/h 实证，
///     2026-10-30 节）；
///   ②审批提醒关（90s 断连倒计时窗口）：完全静默（setRelaySilent——
/// 不发心跳不看门狗，服务器 120s 静默容忍已实证；早前批次
///     的 30s 慢档是该窗口的过渡档）。
/// 档位本身的切换行为在 relay_v2_test「后台自适应心跳」「完全静默档」
/// 用例覆盖；本文件锁 AppState→ComputerStack 接线。
class _HeartbeatProbeStack extends ComputerStack {
  _HeartbeatProbeStack()
    : super(
        profile: AccountV2Profile(
          deviceSid: 'device-hb',
          accountId: 'account-hb',
          label: '心跳接线测试',
          addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        onLog: (_) {},
        onFailure: (_, _) {},
      );

  final List<bool> heartbeatTiers = [];
  final List<bool> silentTiers = [];
  int suspendConversationCalls = 0;

  @override
  void setRelayBackgroundHeartbeat(bool enabled) =>
      heartbeatTiers.add(enabled);

  @override
  void setRelaySilent(bool silent) => silentTiers.add(silent);

  @override
  Future<void> suspendConversationSubscriptions() async {
    suspendConversationCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('90s 断连倒计时分支（审批提醒关）：完全静默替代慢档，不驻留订阅', () {
    final app = AppState();
    final stack = _HeartbeatProbeStack();
    app.debugRegisterStackForTest(stack);
    addTearDown(app.dispose);
    addTearDown(stack.dispose);

    expect(
      app.uiPrefs.alertsEnabled,
      isFalse,
      reason: '前置：审批提醒默认关，onAppPaused 走 90s 断连倒计时分支',
    );
    app.onAppPaused();
    expect(
      stack.silentTiers,
      [true],
      reason: '优化批 #17：倒计时窗口应进完全静默（不发心跳、不看门狗）',
    );
    expect(
      stack.heartbeatTiers,
      isEmpty,
      reason: '优化批 #17：该窗口不再切 30s 慢档（早前批次 过渡档退役）',
    );
    expect(
      stack.suspendConversationCalls,
      0,
      reason: '驻留只在保活分支——倒计时窗口连接本就要拆除，整栈 suspend 覆盖',
    );

    app.onAppResumed();
    expect(
      stack.silentTiers,
      [true, false],
      reason: '回前台退出静默（poke 探活兜底）',
    );
    expect(
      stack.heartbeatTiers,
      [false],
      reason: '回前台恢复前台快档',
    );
  });

  test('保活分支（审批提醒开）：30s 慢档 + 驻留会话明细订阅', () async {
    // 审批提醒开走 AppState.setAlertsEnabled：'companion/notify' 通道挂
    // mock 让 startForeground 成功（否则失败回弹成关，走不进保活分支）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('companion/notify'), (
          call,
        ) async {
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('companion/notify'), null);
    });

    final app = AppState();
    final stack = _HeartbeatProbeStack();
    app.debugRegisterStackForTest(stack);
    addTearDown(app.dispose);
    addTearDown(stack.dispose);

    await app.setAlertsEnabled(true);
    expect(app.uiPrefs.alertsEnabled, isTrue, reason: '前置：审批提醒已开');

    app.onAppPaused();
    expect(
      stack.heartbeatTiers,
      [true],
      reason: '优化批 #16：保活分支维持 30s 慢档心跳',
    );
    expect(
      stack.silentTiers,
      isEmpty,
      reason: '保活分支不进静默档（连接常驻需心跳保活）',
    );
    expect(
      stack.suspendConversationCalls,
      1,
      reason: '优化批 #16：保活分支退后台驻留会话明细订阅（si/tasks-index 保留）',
    );

    app.onAppResumed();
    expect(
      stack.silentTiers,
      [false],
      reason: '回前台统一退出静默（幂等清理，静默本未开）',
    );
    expect(
      stack.heartbeatTiers,
      [true, false],
      reason: '回前台恢复前台快档',
    );
    expect(
      stack.suspendConversationCalls,
      1,
      reason: '驻留只随退后台触发；回前台走 ensureConversation 惰性恢复路径',
    );
  });
}
