import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';

/// 电量优化批 #16（2026-10-31）：会话明细订阅后台驻留（park）——
/// 协议层退订（桌面停止推流式帧）但保留订阅对象与状态（页面持有的引用
/// 继续有效），恢复=增量续订（带当前水位 base，服务端只补 delta）。
/// 本文件在传输层钉死驻留语义；AppState→ComputerStack 接线在
/// battery_heartbeat_wiring_test，relay 静默档在 relay_v2_test。
class _ParkChannel extends ChannelClient {
  _ParkChannel() : super(sendBody: (_) {});

  final calls = <(String, Map<String, dynamic>)>[];
  int _subscribeAcksIssued = 0;

  /// 可选闸门：subscribe/unsubscribe RPC 挂起（制造 park/订阅在飞窗口）。
  Completer<void>? subscribeGate;
  Completer<void>? unsubscribeGate;

  /// sendConversationCommandV4 收到的 commandId（按序）。
  final commandIds = <String>[];
  int _createSessionSeq = 0;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((
      method,
      args.isEmpty
          ? const <String, dynamic>{}
          : (args.first as Map).cast<String, dynamic>(),
    ));
    switch (method) {
      case 'helloConversationV4':
        return {'connectionId': 'conn-park'};
      case 'initializeConversationV4':
        return {'ok': true};
      case 'subscribeConversationV4':
        if (subscribeGate != null) {
          final gate = subscribeGate;
          subscribeGate = null;
          await gate!.future;
        }
        _subscribeAcksIssued++;
        return {
          'ack': {
            'subscriptionId': 'sub-$_subscribeAcksIssued',
            'mode': 'snapshot',
            'logEpoch': 'e1',
          },
        };
      case 'unsubscribeConversationV4':
        if (unsubscribeGate != null) {
          final gate = unsubscribeGate;
          unsubscribeGate = null;
          await gate!.future;
        }
        return {'ok': true};
      case 'sendConversationCommandV4':
        final envelope = calls.last.$2['envelope'];
        final commandId = envelope is Map ? '${envelope['commandId']}' : '';
        commandIds.add(commandId);
        if (calls.last.$2['envelope'] is Map &&
            (calls.last.$2['envelope'] as Map)['type'] == 'createSession') {
          _createSessionSeq++;
          return {
            'status': 'accepted',
            'result': {'sessionId': 'new-s-$_createSessionSeq'},
          };
        }
        return {'status': 'accepted'};
      default:
        return <String, dynamic>{};
    }
  }
}

class _ParkBridge implements BridgeSession {
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
  ChannelClient get channels => _channel;
  final _ParkChannel _channel = _ParkChannel();
  @override
  String? get workspaceKey => 'ws-park';
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

int _callsOf(_ParkChannel channel, String method) =>
    channel.calls.where((c) => c.$1 == method).length;

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late _ParkBridge bridge;
  late ConversationTransport conv;

  setUp(() {
    bridge = _ParkBridge();
    conv = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': r'G:\Demo App'},
    );
  });

  test('驻留：协议层退订 + 对象/状态保留；桥恢复不自愈；恢复走增量续订', () async {
    final sub = await conv.subscribe('s-park');
    addTearDown(sub.dispose);
    expect(sub.subscriptionId, 'sub-1');
    expect(sub.isDisposed, isFalse);

    // ---- 驻留：退订 wire 信封带 subId，对象保留（非 dispose）
    await conv.parkConversationSubscriptionsForBackground();
    final unsub = bridge._channel.calls
        .firstWhere((c) => c.$1 == 'unsubscribeConversationV4')
        .$2;
    expect(unsub['subscriptionId'], 'sub-1', reason: '驻留=协议层退订当前订阅');
    expect(unsub['workspacePath'], r'G:\Demo App', reason: 'scope 平铺同订阅');
    expect(
      sub.subscriptionId,
      isNull,
      reason: '驻留后无订阅 ID（帧监听已摘，桌面不再推帧）',
    );
    expect(
      sub.isDisposed,
      isFalse,
      reason: '驻留≠dispose：对象与状态保留，页面持有的引用继续有效',
    );

    // ---- 桥恢复不唤醒驻留订阅（后台驻留的目的就是不收帧）
    final subscribesBefore = _callsOf(bridge._channel, 'subscribeConversationV4');
    bridge.recovered.value++; // 模拟保活后台中 relay 抖动后桥恢复
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      _callsOf(bridge._channel, 'subscribeConversationV4'),
      subscribesBefore,
      reason: '驻留订阅不随桥恢复自愈重订阅',
    );

    // ---- 恢复：增量续订（带当前水位 base）
    // （注：上方桥恢复已按设计作废握手缓存——恢复链重跑 hello 属正确
    // 语义（新桥=新通道），此处只钉增量续订水位。）
    final resumed = await conv.resumeParkedConversation('s-park');
    expect(resumed, isTrue, reason: '驻留订阅恢复应返回 true');
    // 恢复链是异步重订阅（resubscribe），等它落地。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final resub = bridge._channel.calls
        .lastWhere((c) => c.$1 == 'subscribeConversationV4')
        .$2;
    expect(resub['sessionId'], 's-park');
    expect(
      (resub['base'] as Map)['logEpoch'],
      'e1',
      reason: '增量续订：带驻留前水位的 base（服务端只补 delta）',
    );
    expect(sub.isDisposed, isFalse);

    // ---- 幂等：非驻留态恢复返回 false（零副作用）
    expect(await conv.resumeParkedConversation('s-park'), isFalse);
    expect(await conv.resumeParkedConversation('s-unknown'), isFalse);
  });

  test('park 窗口内落地的订阅立即驻留（开源审查 G1/G2/G3 P2-1：无僵尸活订阅）', () async {
    // subscribe 在飞（`_subscriptions` 只在成功后登记，park 快照不含它）
    // 时退后台——旧实现订阅照常落地：帧监听+服务端订阅+看门狗全活，
    // 后台整段收流式帧（电量红线）。修复=落地即拒绝（退订+人话错误），
    // 回前台重试恢复。
    final subGate = Completer<void>();
    bridge._channel.subscribeGate = subGate;
    final subscribing = conv.subscribe('s-race');
    await _until(
      () => _callsOf(bridge._channel, 'subscribeConversationV4') == 1,
    );
    await conv.parkConversationSubscriptionsForBackground();
    expect(
      _callsOf(bridge._channel, 'unsubscribeConversationV4'),
      0,
      reason: 'park 时刻该订阅尚未登记，无退订可发',
    );
    // 订阅 ACK 迟到落地——拒绝且不留孤儿订阅。
    subGate.complete();
    await expectLater(subscribing, throwsStateError);
    final unsub = bridge._channel.calls
        .firstWhere((c) => c.$1 == 'unsubscribeConversationV4')
        .$2;
    expect(unsub['subscriptionId'], 'sub-1', reason: '迟到 ACK 的订阅立即退订');
    // 回前台重试：subscribe 发起=前台信号（清除驻留态），正常落地。
    final sub = await conv.subscribe('s-race');
    addTearDown(sub.dispose);
    expect(sub.subscriptionId, 'sub-2');
  });

  test('park 迭代期间新完成的订阅收尾补扫驻留（开源审查 G3 P2-1 对称变体）', () async {
    final s1 = await conv.subscribe('s-1');
    addTearDown(s1.dispose);
    // s-1 的 park 挂在退订 RPC（制造 park 循环的 await 窗口）。
    final unsubGate = Completer<void>();
    bridge._channel.unsubscribeGate = unsubGate;
    final parking = conv.parkConversationSubscriptionsForBackground();
    await _until(
      () => _callsOf(bridge._channel, 'unsubscribeConversationV4') == 1,
    );
    // park 快照（toList）只含 s-1；窗口内 s-2 的 subscribe 完成登记。
    final s2 = await conv.subscribe('s-2');
    addTearDown(s2.dispose);
    expect(s2.subscriptionId, 'sub-2');
    unsubGate.complete();
    await parking;
    expect(
      s2.subscriptionId,
      isNull,
      reason: '红：旧实现漏网订阅保持活订阅在后台收帧',
    );
    expect(
      _callsOf(bridge._channel, 'unsubscribeConversationV4'),
      2,
      reason: '补扫对漏网订阅补发退订',
    );
    final lastUnsub = bridge._channel.calls
        .lastWhere((c) => c.$1 == 'unsubscribeConversationV4')
        .$2;
    expect(lastUnsub['subscriptionId'], 'sub-2');
  });

  test('createSession 的 commandId 转正到新会话键（开源审查 G1 P2-2/G2 P2-5）', () async {
    final newSid = await conv.createSession('ws-1', firstText: 'hi');
    expect(newSid, 'new-s-1');
    expect(bridge._channel.commandIds, hasLength(1));
    expect(
      conv.lastCommandIdOf(newSid),
      bridge._channel.commandIds.single,
      reason: '红：旧实现 createSession 信封 sessionId 恒 null，A3 确权记录'
          '永不落位——新会话首条消息超时后无「重新核对」可查',
    );
    expect(conv.lastCommandIdOf('__pendingCreateSession__'), isNull,
        reason: '假键不得残留');
  });
}
