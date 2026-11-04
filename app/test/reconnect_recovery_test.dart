import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/crc32.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/relay_client.dart'
    show RelayState;
import 'package:zcode_pocket/transport/relay_v2.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

import 'fake_relay_v2.dart';

/// 断线恢复批（2026-10-26，用户真机报障"一直断线重连不回来，退出后
/// 切工作区才能恢复 + 切工作区第一下点不动"）红绿：
/// - D1 工作区重驱动：断线窗口内切换/打开失败留下的死端（relay paired
///   但桥未建）此前无任何自动补开——用户必须手点工作区自救；修复后
///   paired 时自动重放原打开意图（含 project/task intent）。
/// - D2 状态详情真话：computeStatusDetail 对 reconnecting/connecting/
///   error 档此前返回空串 → 横幅渲染"连接恢复中…（）"空括号。
/// - D4 pause/resume 竞态：resume 落在 suspend 的 await 窗口内时按
///   suspended（_client==null）误判而只 poke，栈被留在悬挂态无人恢复。
const _timing = RelayV2Timing(
  heartbeatBase: Duration(milliseconds: 40),
  heartbeatJitter: Duration.zero,
  ackTimeout: Duration(milliseconds: 300),
  waitingTimeout: Duration(milliseconds: 200),
  deviceOfflineGrace: Duration(milliseconds: 200),
  backoffInitial: Duration(milliseconds: 10),
  backoffMax: Duration(milliseconds: 50),
  kickFirstMin: Duration(milliseconds: 10),
  kickFirstMax: Duration(milliseconds: 20),
  kickWindow: Duration(milliseconds: 400),
);

Future<bool> until(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return cond();
}

class _StubBridge implements BridgeSession {
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
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => null;
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

/// dispose 可阻塞的 si 替身（D4 竞态窗口控制：suspend 卡在
/// _closeWorkspaceStack 的 await 上）。
class _BlockingSi implements SessionsIndexSubscription {
  _BlockingSi(this.gate);
  final Completer<void> gate;
  @override
  SessionsIndexState get state => SessionsIndexState();
  @override
  String? get subscriptionId => 'si-block';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'sessions-index/block';
  @override
  Future<void> dispose() => gate.future;
}

const _p1 = {
  'id': 'p-1',
  'hostId': 'local',
  'name': '示例项目',
  'roots': [
    {'rootPath': r'G:\示例项目', 'isPrimary': true},
  ],
  'deleted': false,
};

const _p2 = {
  'id': 'p-2',
  'hostId': 'local',
  'name': '另一个项目',
  'roots': [
    {'rootPath': r'G:\另一个项目', 'isPrimary': true},
  ],
  'deleted': false,
};

ComputerStack _stack(CompanionClient client) => ComputerStack(
  profile: AccountV2Profile(
    deviceSid: 'sid-seed',
    deviceMid: 'mid',
    deviceName: '测试桌面',
    appVersion: 'test',
    label: '测试桌面',
    addedAt: DateTime.now(),
  ),
  onLog: (_) {},
  onFailure: (_, _) {},
);

void main() {
  group('relay 自愈（T1：网络中断→恢复，relay 必须自己连回来）', () {
    test('服务器关闭→重启同端口+桌面上线 → client 回 paired', () async {
      final fake = FakeRelayV2();
      // 开源审查 R1-P2-4/R2-P2-2：固定端口 bind 冲突即整文件环境性红——
      // 首绑走 port: 0 内核分配；"同端口重启"语义保留（重启复用同一
      // 分配端口，客户端端点不变、自愈不换端点）。
      await fake.start();
      final port = fake.origin.port;
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);

      final client = RelayV2Client(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        timing: _timing,
      );
      client.start();
      expect(await until(() => client.state == RelayState.paired), isTrue);

      // 网络死亡：服务器整体关闭（HTTP+WS 全断）。
      await fake.close();
      await device.close();
      expect(
        await until(() => client.state == RelayState.reconnecting),
        isTrue,
        reason: '服务器关闭后应进入重连循环（而非终态）',
      );

      // 网络恢复：同端口重启（首绑动态分配的端口）+ 桌面重连。
      await fake.start(port: port);
      final device2 = await fake.connectDevice(sid);
      expect(
        await until(
          () => client.state == RelayState.paired,
          // 负载余量（测试稳定性根治 2026-10-29 批次）：断言为次序/计数
          // 语义，满载套件下事件循环拉长时紧上限偶发不足（已知偶发家族）。
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
        reason: '网络恢复后 relay 层必须自动回到 paired——真机报障的'
            '"重连不回来"实为工作区层死端（D1），此处钉死 relay 自身无此问题',
      );
      await client.dispose();
      await device2.close();
      await fake.close();
    });
  });

  group('D1 工作区重驱动（paired 且桥未建 → 自动重放打开意图）', () {
    late FakeRelayV2 fake;
    late CompanionClient client;
    late ComputerStack stack;
    final opens = <Map<String, dynamic>>[];

    setUp(() async {
      fake = FakeRelayV2();
      await fake.start(); // 动态端口（无同端口重启语义，R1-P2-4/R2-P2-2）
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      // 假桌面：workspace-bridge-open 一律快速拒（真机"桌面拒开桥"形态，
      // 如冷工作区未唤醒/目标不在 tabs）——让打开快速失败进死端。
      device.onData.listen((p) {
        if (p['zcode_type'] == 'workspace-bridge-open') {
          opens.add(p);
          device.sendPayload({
            'zcode_type': 'workspace-bridge-error',
            'bridgeSessionId': p['bridgeSessionId'],
            'error': 'simulated-cold-workspace',
          });
        }
      });

      client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: fake.origin,
          deviceSid: sid,
          deviceName: '测试桌面',
          appVersion: 'test',
        ),
        jwtProvider: () async => 'jwt-alice',
        timing: _timing,
      );
      client.connect();
      stack = _stack(client);
      stack.debugSeedProjectWorkspaceForTest(
        workspace: const {
          'workspacePath': r'G:\示例项目',
          'label': '示例项目',
          'kind': 'local',
        },
        seedProjects: const [_p1, _p2],
        seedTasks: const [],
        bridge: _StubBridge(),
        sessionsIndex: _BlockingSi(Completer<void>()..complete()),
        client: client,
      );
      opens.clear();
    });

    tearDown(() async {
      stack.dispose();
      await client.dispose();
      await fake.close();
    });

    test('切换失败后死端：paired 且桥未建 → 重驱动持续补开（修复前=2 次后永静默）', () async {
      unawaited(stack.switchToProject(_p2));
      // 修复前：用户一次点按 = openWithRetry 两连发（0s+2s）后
      // workspaceError 死端静默，只能手点工作区自救；修复后：重驱动在
      // paired 下自动补开（第 3 次起=重驱动，之后按 3s/30s 节奏续跑）。
      expect(
        await until(
          () => opens.length >= 3,
          // 负载余量（测试稳定性根治 2026-10-29 批次）：断言为次序/计数
          // 语义，满载套件下事件循环拉长时紧上限偶发不足（已知偶发家族）。
          timeout: const Duration(seconds: 20),
        ),
        isTrue,
        reason: '重驱动应自动补开工作区（opens=${opens.length}）——'
            '修复前停在 2（用户手点才恢复）',
      );
      // 第 3 次开桥在飞时：workspaceError 已被新一轮打开清空、
      // workspaceOpening=true——这正是"自动重新打开"的呈现态。
      expect(stack.workspaceOpening, isTrue, reason: '重驱动的打开在飞');
      expect(stack.workspaceRestoring, isTrue, reason: 'paired+无桥=工作区恢复态');
      expect(
        stack.computeStatusDetail(),
        '中继已连，正在恢复工作区',
        reason: 'D2：此态此前返回空串（横幅空括号）',
      );
    });

    test('同一 paired 边沿重复通知只触发一次重驱动开桥', () async {
      unawaited(stack.switchToProject(_p2));
      expect(
        await until(
          () => stack.workspaceError != null,
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
      );
      opens.clear();
      stack.debugOnRelayStateForTest();
      stack.debugOnRelayStateForTest();
      expect(
        await until(() => opens.isNotEmpty),
        isTrue,
        reason: 'paired 边沿应重放原打开意图',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        opens,
        hasLength(1),
        reason: '同一边沿的重复通知不得并发开出第二条桥；2s 冷重试属后续独立尝试',
      );
      expect(opens.single['project'], isA<Map<dynamic, dynamic>>());
    });

    test('redrive 不劫持已恢复的工作区（review-fix-1 A5：触发时复查桥状态）', () async {
      unawaited(stack.switchToProject(_p2));
      // 用户两连发（opens 1-2）+ 首次重驱动重放自身也是两连发（opens 3-4）
      // ——等重放完全落地（opening 回落=finally 已排定 3s 档下一次）再设闸。
      expect(
        await until(
          () => opens.length >= 4 && !stack.workspaceOpening,
          timeout: const Duration(seconds: 20),
        ),
        isTrue,
        reason: '前置：两轮两连发已落地（opens=${opens.length}）',
      );
      // 此刻下一个 redrive（3s 档）已排定——模拟"用户手动打开在飞/成功"
      // 期间（workspaceOpening/桥在场）。直接置公有档位字段压触发点复查
      // 这道闸（真实打开成功路径另有定时器撤销，见 _openActiveWorkspace）。
      stack.workspaceOpening = true;
      addTearDown(() => stack.workspaceOpening = false);
      final countAtGate = opens.length;
      await Future<void>.delayed(const Duration(milliseconds: 4500));
      expect(opens.length, countAtGate,
          reason: '修复前：排定的旧意图照常触发，拆掉用户正在打开/刚恢复'
              '的桥（表现为一次莫名的断连+转圈）');
      stack.workspaceOpening = false;
    });

    test('手动重试重放原意图：payload 携带 project intent（修复前=占位键裸开）', () async {
      unawaited(stack.switchToProject(_p2));
      expect(
        await until(
          () => stack.workspaceError != null,
          // 负载余量（测试稳定性根治 2026-10-29 批次）：断言为次序/计数
          // 语义，满载套件下事件循环拉长时紧上限偶发不足（已知偶发家族）。
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
      );
      opens.clear();
      unawaited(stack.retryWorkspaceOpen());
      expect(
        await until(() => opens.isNotEmpty, timeout: const Duration(seconds: 15)),
        isTrue,
        reason: '重试应重新发出 bridge-open',
      );
      expect(
        opens.first['project'],
        isA<Map<dynamic, dynamic>>(),
        reason: '重试必须携带 project intent（占位 activeWorkspace 不含 '
            'intent，桌面会以"目标工作区不在当前窗口"再拒）',
      );
      expect((opens.first['project'] as Map)['projectId'], 'p-2');
    });
  });

  group('D2 状态详情（空括号根治）', () {
    test('reconnecting 档给真话（修复前=空串）', () async {
      final fake = FakeRelayV2();
      await fake.start(); // 动态端口（无同端口重启语义，R1-P2-4/R2-P2-2）
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);

      final client = CompanionClient.v2(
        config: RelayV2Config(endpointOrigin: fake.origin, deviceSid: sid),
        jwtProvider: () async => 'jwt-alice',
        timing: _timing,
      );
      client.connect();
      final stack = _stack(client);
      stack.debugSeedProjectWorkspaceForTest(
        workspace: const {'workspacePath': r'G:\示例项目', 'kind': 'local'},
        seedProjects: const [_p1],
        seedTasks: const [],
        bridge: _StubBridge(),
        sessionsIndex: _BlockingSi(Completer<void>()..complete()),
        client: client,
      );

      await device.close();
      await fake.close();
      expect(
        await until(
          () => client.relay.state == RelayState.reconnecting,
          // 负载余量（测试稳定性根治 2026-10-29 批次）。
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
      );
      expect(
        stack.computeStatusDetail(),
        anyOf('连接已断开，自动重连中', '正在建立连接'),
        reason: '非 paired 档详情必须非空——修复前 computeStatusDetail 对 '
            'reconnecting/connecting/error 返回空串，横幅渲染"（）"',
      );
      stack.dispose();
      await client.dispose();
    });
  });

  group('D4 pause/resume 竞态（resume 落在 suspend 的 await 窗口内）', () {
    test('resume 抢跑后栈悬挂（旧行为复现）→ pokeOrResume 落地后恢复', () async {
      final client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: Uri.parse('http://127.0.0.1:1'),
          deviceSid: 'sid-seed',
        ),
        jwtProvider: () async => null,
      );
      final stack = _stack(client);
      final gate = Completer<void>();
      stack.debugSeedProjectWorkspaceForTest(
        workspace: const {'workspacePath': r'G:\示例项目', 'kind': 'local'},
        seedProjects: const [_p1],
        seedTasks: const [],
        bridge: _StubBridge(),
        sessionsIndex: _BlockingSi(gate),
        client: client,
      );

      final suspending = stack.suspend(); // 卡在 si dispose（不 await）
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 旧行为（红演示）：resume 见 _client 未清 → 空转返回。
      await stack.resume();
      expect(stack.suspended, isFalse, reason: 'suspend 未落地，_client 仍在');

      gate.complete(); // suspend 落地
      await suspending;
      expect(
        stack.suspended,
        isTrue,
        reason: '红：resume 已消费，栈悬挂无人恢复（真机"回 app 一直转圈"）',
      );

      // 修复面：pokeOrResume 对已悬挂栈恢复。
      unawaited(stack.pokeOrResume());
      expect(
        await until(() => !stack.suspended),
        isTrue,
        reason: 'pokeOrResume 应恢复悬挂栈',
      );
      await stack.disposeStack();
    });

    test('pokeOrResume 在 suspend 落地中调用 → 等待落地后恢复（不悬挂）', () async {
      final client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: Uri.parse('http://127.0.0.1:1'),
          deviceSid: 'sid-seed',
        ),
        jwtProvider: () async => null,
      );
      final stack = _stack(client);
      final gate = Completer<void>();
      stack.debugSeedProjectWorkspaceForTest(
        workspace: const {'workspacePath': r'G:\示例项目', 'kind': 'local'},
        seedProjects: const [_p1],
        seedTasks: const [],
        bridge: _StubBridge(),
        sessionsIndex: _BlockingSi(gate),
        client: client,
      );

      final suspending = stack.suspend();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      unawaited(stack.pokeOrResume()); // suspend 仍在飞行中
      gate.complete();
      await suspending;
      expect(
        await until(() => !stack.suspended),
        isTrue,
        reason: 'D4：pokeOrResume 须等 suspend 落地再判定——修复前 resume '
            '在此窗口抢跑后栈永久悬挂',
      );
      await stack.disposeStack();
    });
  });

  // 开源审查 H1-P1-01：_attachStack 的旧 bridgeSessionId 在 _swap 之后才
  // 读——swap 后 session._bridge 已是新桥，oldId 恒等于新 id，remove 永不
  // 生效。后果：每次桥重开泄漏一个 router 条目（指向已 dispose 的旧
  // transport），迟到旧帧（relay 对旧帧有重投/乱序语义）会打进已 close
  // 的 _messageController——StateError 从 payloads 监听器逃逸成未捕获
  // 异步错误（本用例即红）。
  group('桥重开后旧 bridgeSessionId 路由残留（开源审查 H1-P1-01）', () {
    test('reopen 换新桥 id：旧 id 路由摘除，迟到旧帧不打进已 dispose 的 transport', () async {
      final fake = FakeRelayV2();
      await fake.start(); // 动态端口（无同端口重启语义，R1-P2-4/R2-P2-2）
      addTearDown(() => fake.close());
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      // 假桌面：bridge-open 一律就绪，桥 id 由桌面权威分配（b-1/b-2 两代，
      // 模拟重开换新 id）；reconnect 探测请求快速应答（真实桌面语义）。
      var bridgeSeq = 0;
      device.onData.listen((p) {
        final t = p['zcode_type'];
        if (t == 'workspace-bridge-open') {
          final id = 'b-${++bridgeSeq}';
          device.sendPayload({
            'zcode_type': 'workspace-bridge-ready',
            'bridgeSessionId': p['bridgeSessionId'],
            'bridge': {
              'bridgeSessionId': id,
              'bridgeGeneration': p['bridgeGeneration'],
              'workspaceKey': p['workspaceKey'],
              'recoveryId': 'rec-$id',
            },
          });
        } else if (t == 'workspace-reconnect-request') {
          device.sendPayload({
            'zcode_type': 'workspace-reconnect-response',
            'requestId': p['requestId'],
            'workspaceKey': p['workspaceKey'],
            'success': true,
          });
        }
      });

      final client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: fake.origin,
          deviceSid: sid,
          deviceName: '测试桌面',
          appVersion: 'test',
        ),
        jwtProvider: () async => 'jwt-alice',
        timing: _timing,
      );
      addTearDown(client.dispose);
      unawaited(client.connect());
      await client.waitPaired();

      final session = await client.openBridge('ws-key');
      expect(session.transport.bridgeSessionId, 'b-1');

      // 触发恢复重开（bridge-degraded → recovery → reopen 换新桥 id）。
      device.sendPayload({
        'zcode_type': 'bridge-degraded',
        'bridgeSessionId': 'b-1',
        'reason': 'rpc-transport-fault',
      });
      expect(
        await until(
          () => session.transport.bridgeSessionId == 'b-2',
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
        reason: 'degraded 应触发重开并换新桥 id（b-2）',
      );

      Uint8List frameMsg(int seq) => utf8.encode('stale-$seq');
      Map<String, dynamic> rpcFrame(String bridgeId, int seq) => {
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': bridgeId,
        'seq': seq,
        'messageSeq': seq,
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'messageBytes': frameMsg(seq).length,
        'checksum': {
          'algorithm': 'crc32',
          'value': Crc32.hexOf(frameMsg(seq)),
        },
        'dataBase64': base64.encode(frameMsg(seq)),
      };

      // 迟到旧帧（b-1）：修复前其路由仍指向已 dispose 的旧 transport——
      // 完整单分片消息向已 close 的 _messageController add 抛 StateError，
      // 从 payloads 监听器逃逸（未捕获异步错误，本用例判红）；修复后旧
      // 路由在 swap 时已摘除，帧静默丢弃。
      device.sendPayload(rpcFrame('b-1', 1));

      // 新桥路由健在：新 id 帧照常送达（防误删）。
      final got = <Uint8List>[];
      final sub = session.transport.messages.listen(got.add);
      addTearDown(sub.cancel);
      device.sendPayload(rpcFrame('b-2', 1));
      expect(
        await until(() => got.isNotEmpty),
        isTrue,
        reason: '新桥 id 的帧应正常送达（新路由未被误删）',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        utf8.decode(got.single),
        'stale-1',
        reason: '只应收到新桥 b-2 的一条消息',
      );
    });
  });
}
