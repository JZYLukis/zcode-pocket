import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/conversation_registry.dart';
import 'package:zcode_pocket/state/task_catalog.dart';
import 'package:zcode_pocket/state/workspace_controller.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/relay_v2.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

import 'fake_relay_v2.dart';

/// 开源审查修复批 B 组3（workspace_controller）红绿：
/// - ①startBootstrapWhenPaired：bootstrap 失败此前 _lastOpenAction 从未
///   设置 + unawaited 无 catch——redrive 自愈链在该路径不存在（J3 P1-3）；
/// - ②openActiveWorkspace 三处 isGone 早退把 workspaceOpening 永久留
///   true：redrive 闸被短路 + spinner 卡死（I2 P2-2）；
/// - ③bootstrap 收尾 switchWorkspace(target) 无新近性守卫：await 窗口内
///   用户手切被反向拆掉（J1-3/J3 P2-1）；
/// - close() 参与 epoch 纪律：外部 close（suspend/disposeStack）的 await
///   窗口内在飞 open 会把桥复活到已释放 client 上（J1-2 半开栈）。

Future<bool> _until(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return cond();
}

class _StubChannels implements ChannelClient {
  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async => const <Object?>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSiSub implements SessionsIndexSubscription {
  _FakeSiSub();
  bool disposed = false;
  @override
  final SessionsIndexState state = SessionsIndexState();
  @override
  bool get isDisposed => disposed;
  @override
  String? get subscriptionId => 'si-fake';
  @override
  String get topic => 'sessions-index/fake';
  @override
  Future<void> dispose() async => disposed = true;
}

class _FakeTiSub implements TasksIndexSubscription {
  @override
  final TasksIndexState state = TasksIndexState();
  @override
  void Function(List<String> removedTaskIds)? onRowsRemoved;
  @override
  bool get isDisposed => false;
  @override
  String? get subscriptionId => 'ti-fake';
  @override
  String get topic => 'controller/tasks-index';
  @override
  Future<void> dispose() async {}
}

class _FakeConv implements ConversationTransport {
  _FakeConv({this.subscribeImpl});

  /// null=返回健康订阅；否则抛出/返回由用例脚本控制。
  final Future<SessionsIndexSubscription> Function()? subscribeImpl;

  @override
  Future<SessionsIndexSubscription> subscribeSessionsIndex({
    int maxAttempts = 3,
  }) async => await (subscribeImpl?.call() ?? _FakeSiSub());

  @override
  SessionsIndexSubscription dormantSessionsIndex() => _FakeSiSub();

  @override
  Future<TasksIndexSubscription> subscribeTasksIndex({
    int maxAttempts = 2,
  }) async => _FakeTiSub();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubBridge implements BridgeSession {
  _StubBridge({this.conv});
  final _FakeConv? conv;
  bool disposed = false;
  final _StubChannels channelsImpl = _StubChannels();

  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  ChannelClient get channels => channelsImpl;
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-stub';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => conv ?? (throw StateError('stub bridge has no conv'));
  @override
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) async {}
  @override
  void dispose() => disposed = true;
}

/// bootstrap/listWorkspaces/openBridge 全脚本化的客户端（离线可跑）。
class _ScriptedClient extends CompanionClient {
  _ScriptedClient.v2({
    required RelayV2Config config,
    required Future<String?> Function() jwtProvider,
  }) : super.v2(config: config, jwtProvider: jwtProvider);

  int bootstrapCalls = 0;
  Completer<void>? bootstrapGate;
  Object? bootstrapError;

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    bootstrapCalls++;
    final gate = bootstrapGate;
    if (gate != null) await gate.future;
    final e = bootstrapError;
    if (e != null) throw e;
    return const <String, dynamic>{};
  }

  dynamic listResult = const <String, dynamic>{};

  @override
  Future<dynamic> listWorkspaces() async => listResult;

  final openCalls = <String>[];
  Future<BridgeSession> Function(String key)? openImpl;

  @override
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    String? taskHostId,
    Map<String, dynamic>? project,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    openCalls.add(workspaceKey);
    final impl = openImpl;
    if (impl == null) throw StateError('openBridge not scripted');
    return impl(workspaceKey);
  }
}

class _Harness {
  _Harness(this.client) {
    final p = AccountV2Profile(
      deviceSid: 'sid-w',
      label: '测试桌面',
      addedAt: DateTime.now(),
    );
    registry = ConversationRegistry(
      cache: null,
      deviceSid: () => p.deviceSid,
      transportProvider: () => controller.conversation,
      siDormantProvider: () => controller.siDormant,
      retrySessionsIndex: () => controller.retrySessionsIndex(),
      disposedProvider: () => disposed,
      onLog: (_) {},
    );
    catalog = TaskCatalog(
      bridgeProvider: () => controller.bridge,
      conversationProvider: () => controller.conversation,
      activeWorkspaceProvider: () => controller.activeWorkspace,
      workspacesProvider: () => controller.workspaces,
      disposedProvider: () => disposed,
      onLog: (_) {},
      onNotify: () {},
      onCacheWrite: () {},
      onTaskListChanged: () {},
      onTaskListRebuilt: (_) {},
    );
    controller = WorkspaceController(
      conversationRegistry: registry,
      taskCatalog: catalog,
      clientProvider: () => client,
      disposedProvider: () => disposed,
      profileProvider: () => p,
      profileSetter: (value) {},
      persistProfile: (value) async {},
      onLog: (_) {},
      onNotify: () {},
      onCacheWrite: () {},
      cancelDeviceCacheWrite: () {},
      flushDeviceCache: ({awaitWrites = true}) async {},
      onBootstrapStarted: () {},
      ensureWorkspaceListSubscription: (_) {},
    );
  }

  final _ScriptedClient client;
  late final ConversationRegistry registry;
  late final TaskCatalog catalog;
  late final WorkspaceController controller;
  bool disposed = false;
}

_ScriptedClient _offlineClient() => _ScriptedClient.v2(
  config: RelayV2Config(
    endpointOrigin: Uri.parse('http://127.0.0.1:1'),
    deviceSid: 'sid-x',
  ),
  jwtProvider: () async => null,
);

void main() {
  group('② isGone 早退复位 workspaceOpening（I2 P2-2）', () {
    test('openWithRetry 返回后 isGone：spinner 复位+桥释放（修复前=永久 true 封死 redrive）', () async {
      final h = _Harness(_offlineClient());
      final bridge = _StubBridge();
      await h.controller.openActiveWorkspace(
        h.client,
        isGone: () => true,
        logKey: 'ws',
        openWithRetry: () async => bridge,
      );
      expect(
        h.controller.workspaceOpening,
        isFalse,
        reason: '修复前：早退不复位，workspaceOpening 残留 true——'
            'maybeScheduleWorkspaceRedrive 的闸被永久短路+开屏 spinner 卡死',
      );
      expect(h.controller.bridge, isNull);
      expect(bridge.disposed, isTrue);
      await h.controller.close();
    });

    test('si 降级分支入口 isGone：spinner 复位且不污染 siDormant（J2 P2-1 陈旧降级）', () async {
      final h = _Harness(_offlineClient());
      var gone = false;
      final conv = _FakeConv(
        subscribeImpl: () async {
          gone = true; // 订阅在途期间外部切换/关闭（isGone 翻转）
          throw TimeoutException('si cold workspace');
        },
      );
      final bridge = _StubBridge(conv: conv);
      // openActiveWorkspace 直调：先就位工作区（否则 outer catch 提前接管，
      // 走不到 si 降级分支）。
      h.controller.activeWorkspace = const {
        'workspacePath': 'G:/w',
        'kind': 'local',
      };
      await h.controller.openActiveWorkspace(
        h.client,
        isGone: () => gone,
        logKey: 'ws',
        openWithRetry: () async => bridge,
      );
      expect(
        h.controller.workspaceOpening,
        isFalse,
        reason: 'isGone 早退必须复位 workspaceOpening（I2 P2-2）',
      );
      expect(
        h.controller.siDormant,
        isFalse,
        reason: '开源审查 J2 P2-1：陈旧 open 的降级入口先验 isGone——修复前'
            '无条件降级会把（新工作区的）siDormant 翻成 true，假降级窗口'
            '最长 60s 靠泄漏定时器自愈',
      );
      await h.controller.close();
    });
  });

  group('开源审查批D组2：openActiveWorkspace 失败路径', () {
    test('外层 catch 的 isGone 守卫：陈旧失败不写 workspaceError（J2 P2-2）', () async {
      final h = _Harness(_offlineClient());
      var gone = false;
      await h.controller.openActiveWorkspace(
        h.client,
        isGone: () => gone,
        logKey: 'ws',
        openWithRetry: () async {
          gone = true; // 开桥失败时本轮已被作废（新切换/外部关闭）
          throw StateError('workspace-bridge-error: stale key');
        },
      );
      expect(
        h.controller.workspaceError,
        isNull,
        reason: '修复前：陈旧失败无条件写 workspaceError——快速连续切换 A→B '
            '时 A 的迟到失败把 B 健康态的错误横幅写脏且无人再清',
      );
    });

    test('si 非降级错误 rethrow：半开栈收尾拆桥（J1-11 残留 bridge 令 redrive 失效）', () async {
      final h = _Harness(_offlineClient());
      final conv = _FakeConv(
        subscribeImpl: () async => throw StateError('si unexpected protocol'),
      );
      final bridge = _StubBridge(conv: conv);
      h.controller.activeWorkspace = const {
        'workspacePath': 'G:/w',
        'kind': 'local',
      };
      await h.controller.openActiveWorkspace(
        h.client,
        isGone: () => false,
        logKey: 'ws',
        openWithRetry: () async => bridge,
      );
      expect(
        h.controller.bridge,
        isNull,
        reason: '修复前：_bridge 已落位而 _sessionsIndex 未建——'
            'maybeScheduleWorkspaceRedrive 以 _bridge!=null 为「已开」代理'
            '被挡，自动重驱动失效',
      );
      expect(bridge.disposed, isTrue);
      expect(h.controller.workspaceError, isNotNull);
      // 人话档（J1-12/J3 P3-3）：原始异常串只进日志，横幅不带英文协议原文。
      expect(h.controller.workspaceError, contains('打开工作区失败'));
      expect(h.controller.workspaceError, isNot(contains('si unexpected')));
    });

    test('workspaceError 分档：桥拒不带协议原文、超时有人话（J1-12）', () async {
      final h = _Harness(_offlineClient());
      h.controller.activeWorkspace = const {
        'workspacePath': 'G:/w',
        'kind': 'local',
      };
      await h.controller.openActiveWorkspace(
        h.client,
        isGone: () => false,
        logKey: 'ws',
        openWithRetry: () async =>
            throw StateError('workspace-bridge-error: {x}'),
      );
      expect(h.controller.workspaceError, contains('拒绝了打开请求'));
      expect(
        h.controller.workspaceError,
        isNot(contains('workspace-bridge-error')),
      );
      h.controller.workspaceError = null;
      await h.controller.openActiveWorkspace(
        h.client,
        isGone: () => false,
        logKey: 'ws',
        openWithRetry: () async => throw TimeoutException('open bridge'),
      );
      expect(h.controller.workspaceError, contains('超时'));
      expect(h.controller.workspaceError, isNot(contains('TimeoutException')));
    });
  });

  group('close() 参与 epoch 纪律（J1-2 半开栈复活）', () {
    test('外部 close 的 await 窗口内在飞 open 弃权：桥不复活到已释放 client 上', () async {
      final h = _Harness(_offlineClient());
      final gate = Completer<void>();
      final bridge = _StubBridge();
      h.client.openImpl = (key) async {
        await gate.future;
        return bridge;
      };
      final switching = h.controller.switchWorkspace(const {
        'workspacePath': 'G:/w1',
        'kind': 'local',
      });
      expect(await _until(() => h.client.openCalls.isNotEmpty), isTrue,
          reason: '前置：open 已在飞（卡在 openBridge）');
      await h.controller.close(); // 外部关闭（suspend/disposeStack 同款入口）
      gate.complete();
      await switching;
      expect(
        h.controller.bridge,
        isNull,
        reason: '修复前：close 落地时 isGone 的 client 身份判定未变'
            '（suspend 清 _client 在 close 之后），在飞 open 照常落位'
            '——桥/订阅全部死在半开栈上，恢复期 bootstrap 被"已有桥"守卫跳过',
      );
      expect(bridge.disposed, isTrue);
      expect(h.controller.workspaceOpening, isFalse);
    });
  });

  group('① startBootstrapWhenPaired 失败自愈（J3 P1-3）', () {
    test('bootstrap 失败：设置 _lastOpenAction 并接 redrive 自动重放（修复前=异常裸飞+调用数停在 1）', () async {
      final fake = FakeRelayV2();
      await fake.start();
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      final client = _ScriptedClient.v2(
        config: RelayV2Config(
          endpointOrigin: fake.origin,
          deviceSid: sid,
          deviceName: '桌面',
          appVersion: 't',
        ),
        jwtProvider: () async => 'jwt-alice',
      )..bootstrapError = TimeoutException('bootstrap rpc');
      final h = _Harness(client);
      client.connect();
      h.controller.startBootstrapWhenPaired(client);
      expect(
        await _until(() => client.bootstrapCalls >= 2),
        isTrue,
        reason: '修复前：本路径 _lastOpenAction 从未设置，'
            'maybeScheduleWorkspaceRedrive 的 action==null 闸空转——'
            'redrive 自愈链不存在（paired+无桥永久死端），且 unawaited 无 catch',
      );
      h.controller.cancelRedrive();
      await h.controller.close();
      await client.dispose();
      await device.close();
      await fake.close();
    });
  });

  group('③ bootstrap 收尾新近性守卫（J1-3/J3 P2-1）', () {
    test('bootstrap await 窗口内用户手切：收尾不拆用户刚开的工作区（修复前=反向覆盖）', () async {
      final h = _Harness(_offlineClient());
      final gate = Completer<void>();
      h.client.bootstrapGate = gate;
      h.client.listResult = {
        'workspaces': [
          {'workspacePath': 'G:/auto-restore', 'kind': 'local'},
        ],
        'tasks': null,
      };
      final userBridge = _StubBridge(conv: _FakeConv());
      h.client.openImpl = (key) async =>
          key == 'G:/user' ? userBridge : _StubBridge();
      final booting = h.controller.bootstrapWorkspace(h.client);
      expect(await _until(() => h.client.bootstrapCalls == 1), isTrue,
          reason: '前置：bootstrap 已进入 await 窗口');
      // 用户手动切换并完整成功（开桥+订阅落位）。
      await h.controller.switchWorkspace(const {
        'workspacePath': 'G:/user',
        'kind': 'local',
      });
      expect(h.controller.bridge, same(userBridge));
      gate.complete(); // bootstrap 恢复执行
      await booting;
      expect(
        h.controller.bridge,
        same(userBridge),
        reason: '修复前：尾部无条件 switchWorkspace(恢复目标) 把用户刚开的桥'
            '拆掉、选择被静默丢弃',
      );
      expect(h.controller.activeWorkspace?['workspacePath'], 'G:/user');
      expect(h.client.openCalls, isNot(contains('G:/auto-restore')),
          reason: '恢复目标不得再发起开桥');
      await h.controller.close();
    });
  });
}
