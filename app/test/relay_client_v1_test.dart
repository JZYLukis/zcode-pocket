import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/relay_client.dart';

/// 协议传输层修复批（2026-11-08）：V1 relay 三洞——
/// ①data 帧无认证/配对门禁 ②setRelaySilent/setBackgroundHeartbeat 空实现
/// （90s 断连窗口仍 10s 心跳=电量红线）③auth_ack 非字符串 pair_status
/// 取消握手 deadline 后无任何定时器（永久挂在 authenticating）。
/// V1 生产只走 wss（单测无法低成本伪造 TLS 握手），故用 debug 缝直接驱动
/// 帧处理与心跳装配（debugDropSocket 同款测试缝范式）。
void main() {
  CompanionConnectionParams params() => CompanionConnectionParams.parse(
    'https://127.0.0.1:1/remote/v4?sid=d_1&hash=hk&t=1',
  )!;

  test('data 帧门禁：未 paired 不交付业务载荷（修复前红）', () async {
    final client = RelayClient(params());
    addTearDown(client.dispose);
    final received = <Map<String, dynamic>>[];
    client.payloads.listen(received.add);

    client.debugSetRelayState(RelayState.authenticating);
    client.debugHandleRelayFrame({
      'type': 'data',
      'payload': {'zcode_type': 'bootstrap-response', 'requestId': 'r1'},
    });
    expect(received, isEmpty, reason: '未认证/未配对的数据帧不得进 payloads');

    client.debugSetRelayState(RelayState.paired);
    client.debugHandleRelayFrame({
      'type': 'data',
      'payload': {'zcode_type': 'bootstrap-response', 'requestId': 'r1'},
    });
    // 广播流投递是异步的。
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
  });

  test('auth_ack 非字符串 pair_status → waiting（修复前红：永停 authenticating）',
      () async {
    final client = RelayClient(params());
    addTearDown(client.dispose);
    client.debugSetRelayState(RelayState.authenticating);
    client.debugHandleRelayFrame({'type': 'auth_ack', 'device_sid': 'd_1'});
    expect(
      client.state,
      RelayState.waiting,
      reason: '旧实现 _applyPairStatus(null)：先取消握手 deadline、不落任何'
          '状态/定时器——永久死态',
    );
  });

  test('F1：陈旧入站 poke 先探针不重连；3s 无应答才重连（修复前红：陈旧即整链重连）', () {
    final client = RelayClient(params());
    addTearDown(client.dispose);
    final sent = <Map<String, dynamic>>[];
    client.debugSetRelayState(RelayState.paired);
    client.debugBlockReconnect = true;
    client.debugCaptureSend(sent.add);

    fakeAsync((async) {
      // 模拟后台静默 60s：入站陈旧。poke 只应发探针，不触发重连。
      client.debugAgeInbound(const Duration(seconds: 60));
      client.poke();
      expect(client.debugReconnectCount, 0,
          reason: '修复前：陈旧即整链重连（每次回前台必重挂）');
      expect(sent, isNotEmpty, reason: '必须先发 pair_status_query 探针');
      expect(sent.last['type'], 'pair_status_query');

      // 3s 看门狗内收到任一入站帧 → 判健康，不重连。
      client.debugHandleRelayFrame(const {'type': 'pair_status', 'status': 'matched'});
      async.elapse(const Duration(seconds: 4));
      expect(client.debugReconnectCount, 0, reason: '探针有应答=链路健康');

      // 再 poke：这次 3s 内无应答 → 重连。
      client.debugAgeInbound(const Duration(seconds: 60));
      client.poke();
      async.elapse(const Duration(seconds: 4));
      expect(client.debugReconnectCount, 1, reason: '探针无应答才允许整链重连');
    });
  });

  test('静默档停心跳、退出恢复；后台档切到慢周期（修复前红：空实现）', () {
    final client = RelayClient(params());
    addTearDown(client.dispose);

    client.debugSetRelayState(RelayState.paired);
    client.debugStartHeartbeat();
    expect(client.debugHeartbeatTimerActive, isTrue);
    expect(client.debugHeartbeatPeriod, RelayClient.heartbeatInterval);

    // 90s 断连倒计时窗口：静默（服务器 120s 静默容忍已实证）。
    client.setRelaySilent(true);
    expect(client.debugHeartbeatTimerActive, isFalse,
        reason: '静默档必须停心跳 Timer（含 tick 内的 ACK 陈旧看门狗）');
    client.debugStartHeartbeat(); // 静默期内的重武装请求同样被闸住
    expect(client.debugHeartbeatTimerActive, isFalse);

    // 回前台恢复默认档。
    client.setRelaySilent(false);
    expect(client.debugHeartbeatTimerActive, isTrue);

    // 后台自适应档：周期放宽到 30s（ACK 陈旧阈值同步放宽，防每拍误判）。
    client.setBackgroundHeartbeat(true);
    expect(client.debugHeartbeatPeriod, RelayClient.backgroundHeartbeatInterval);
    expect(client.debugHeartbeatTimerActive, isTrue);
    client.setBackgroundHeartbeat(false);
    expect(client.debugHeartbeatPeriod, RelayClient.heartbeatInterval);
  });
}
