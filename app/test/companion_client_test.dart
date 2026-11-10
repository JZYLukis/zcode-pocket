import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/relay_v2.dart';

import 'fake_relay_v2.dart';

/// 协议传输层修复批（2026-11-08）：CompanionClient 的 L2 语义——
/// ①app-error 通用立即失败（官方 payloadRequester.ts:115-124）
/// ②bridge-degraded 的 terminal-owner 原因走慢档恢复 + 人话文案
/// （官方 desktop 在另一终端接管该桥；官方 reason 表 validation.ts:480-489）。
class _FakeDesktop {
  _FakeDesktop(this.device);

  final FakeDeviceSide device;

  /// workspace-bridge-open 是否回 error（模拟"接管方未退出，重开注定被拒"）。
  bool failOpens = false;

  /// 收到的 bridge-open 次数（慢档节奏断言靶）。
  int opens = 0;

  /// 最近一次 bootstrap-request 的 requestId（app-error 注入用）。
  String? bootstrapRequestId;

  static _FakeDesktop attach(FakeDeviceSide device) {
    final desktop = _FakeDesktop(device);
    device.onData.listen(desktop._onPayload);
    return desktop;
  }

  void _onPayload(Map<String, dynamic> payload) {
    final type = payload['zcode_type'];
    final requestId = payload['requestId'];
    switch (type) {
      case 'bootstrap-request':
        bootstrapRequestId = requestId is String ? requestId : null;
        break;
      case 'workspace-reconnect-request':
        // 官方语义：本地桥恒回 success 但不重建——恢复判定只认 reopen。
        device.sendPayload({
          'zcode_type': 'workspace-reconnect-response',
          'requestId': requestId,
          'workspaceKey': payload['workspaceKey'],
          'success': false,
        });
        break;
      case 'workspace-bridge-open':
        opens++;
        if (failOpens) {
          device.sendPayload({
            'zcode_type': 'workspace-bridge-error',
            'bridgeSessionId': payload['bridgeSessionId'],
            'error': 'denied (terminal owner holds the bridge)',
          });
        } else {
          device.sendPayload({
            'zcode_type': 'workspace-bridge-ready',
            'requestId': requestId,
            'bridgeSessionId': payload['bridgeSessionId'],
            'bridge': {
              'bridgeSessionId': payload['bridgeSessionId'],
              'bridgeGeneration': payload['bridgeGeneration'],
              'workspaceKey': payload['workspaceKey'],
              'recoveryId': 'rec-1',
            },
          });
        }
        break;
    }
  }
}

typedef _Harness = ({
  FakeRelayV2 fake,
  FakeDeviceSide device,
  CompanionClient client,
  _FakeDesktop desktop,
  String sid,
});

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  const timing = RelayV2Timing(
    heartbeatBase: Duration(milliseconds: 60),
    heartbeatJitter: Duration.zero,
    ackTimeout: Duration(milliseconds: 400),
    waitingTimeout: Duration(milliseconds: 400),
    deviceOfflineGrace: Duration(milliseconds: 200),
    backoffInitial: Duration(milliseconds: 20),
    backoffMax: Duration(milliseconds: 80),
    kickFirstMin: Duration(milliseconds: 10),
    kickFirstMax: Duration(milliseconds: 20),
    kickWindow: Duration(milliseconds: 400),
  );

  Future<_Harness> setUpHarness({List<String>? logs}) async {
    final fake = FakeRelayV2();
    await fake.start();
    final sid = fake.registerDevice('jwt-alice');
    final device = await fake.connectDevice(sid);
    final desktop = _FakeDesktop.attach(device);
    final client = CompanionClient.v2(
      config: RelayV2Config(
        endpointOrigin: fake.origin,
        deviceSid: sid,
        deviceName: '测试机',
        appVersion: 'test',
      ),
      jwtProvider: () async => 'jwt-alice',
      timing: timing,
      onLog: logs == null ? null : logs.add,
      fastRecoveryDelay: const Duration(milliseconds: 10),
      slowRecoveryDelay: const Duration(milliseconds: 200),
    );
    addTearDown(() => fake.close());
    addTearDown(device.close);
    addTearDown(client.dispose);
    client.connect();
    await client.waitPaired();
    return (
      fake: fake,
      device: device,
      client: client,
      desktop: desktop,
      sid: sid,
    );
  }

  test('app-error 带 requestId 命中在途请求 → 立即失败（不等 30s 超时）', () async {
    final h = await setUpHarness();
    final future = h.client.bootstrap();
    await _until(() => h.desktop.bootstrapRequestId != null);
    final requestId = h.desktop.bootstrapRequestId!;
    final clock = Stopwatch()..start();
    h.device.sendPayload({
      'zcode_type': 'app-error',
      'requestId': requestId,
      'reason': 'rpc-transport-fault',
      'error': 'bridge gone',
    });
    await expectLater(
      future,
      throwsA(
        isA<RemoteAppError>()
            .having((e) => e.reason, 'reason', 'rpc-transport-fault')
            .having((e) => e.error, 'error', 'bridge gone'),
      ),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)),
        reason: '修复前：干等 bootstrap 请求 30s 超时');
  });

  test('createWorkspace 的 app-error 人话特判保留（不被通用分支抢走）', () async {
    final h = await setUpHarness();
    h.device.onData.listen((payload) {
      if (payload['zcode_type'] == 'workspace-create-request') {
        h.device.sendPayload({
          'zcode_type': 'app-error',
          'requestId': payload['requestId'],
          'reason': 'rpc-transport-fault',
          'error': 'unknown action',
        });
      }
    });
    await expectLater(
      h.client.createWorkspace('demo'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('该电脑版本不支持在手机上新建项目'),
        ),
      ),
    );
  });

  test('terminal-owner-ended：degraded 人话文案 + 慢档恢复；接管释放后自愈', () async {
    final logs = <String>[];
    final h = await setUpHarness(logs: logs);
    final session = await h.client.openBridge('wk-1');
    expect(session.bridge['bridgeSessionId'], isNotNull);
    expect(h.desktop.opens, 1);

    // 接管方持有桥：后续 reopen 一律被拒。
    h.desktop.failOpens = true;
    final opensBefore = h.desktop.opens;
    h.device.sendPayload({
      'zcode_type': 'bridge-degraded',
      'bridgeSessionId': session.bridge['bridgeSessionId'],
      'reason': 'terminal-owner-ended',
    });
    await _until(() => session.degraded.value == terminalOwnerDegradedMessage);
    expect(h.client.debugSlowRecovery(session), isTrue);

    // 慢档节奏：700ms 内至多 ~4 次尝试（快档 10ms 会是几十次）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final attempts = h.desktop.opens - opensBefore;
    expect(attempts, greaterThanOrEqualTo(2),
        reason: '慢档仍应持续单发尝试（接管方可能已退出）');
    expect(attempts, lessThanOrEqualTo(5),
        reason: '慢档 200ms 单发，不得退化成 10ms 快重试循环');
    expect(session.degraded.value, terminalOwnerDegradedMessage,
        reason: '慢档期间保持人话文案，不被内部状态串覆盖');

    // 接管方退出：下一次慢档尝试重开成功，degraded 清空。
    h.desktop.failOpens = false;
    await _until(() => session.degraded.value == null);
    expect(h.client.debugSlowRecovery(session), isFalse);
    expect(
      logs.any((l) => l.contains('terminal owner taken over')),
      isTrue,
      reason: '慢档启用应留痕',
    );
  });

  test('普通 reason（rpc-transport-fault）维持快档恢复，不进入慢档', () async {
    final h = await setUpHarness();
    final session = await h.client.openBridge('wk-1');
    h.desktop.failOpens = true;
    final opensBefore = h.desktop.opens;
    h.device.sendPayload({
      'zcode_type': 'bridge-degraded',
      'bridgeSessionId': session.bridge['bridgeSessionId'],
      'reason': 'rpc-transport-fault',
    });
    await _until(() => session.degraded.value != null);
    expect(h.client.debugSlowRecovery(session), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(h.desktop.opens - opensBefore, greaterThanOrEqualTo(3),
        reason: '快档 10ms 重试在 300ms 内应有多轮（慢档 200ms 至多 2 轮）');
  });
}
