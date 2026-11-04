import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/transport/relay_v2.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

/// H10 红绿（2026-10-25 批①）：「任务」聚合视图点回原项目被幂等门
/// 误跳过——真 ComputerStack 状态机旅程（门逻辑跑本尊，桥/索引/客户端
/// 为离线替身；种子缝=debugSeedProjectWorkspaceForTest）。
/// 修复前红：P→任务→点回 P 后 activeProjectId 停在伪项目（界面不动）。
/// 原有 unclassified_tasks_test 用 FakeAppState 覆写切换方法，覆盖不到
/// 本状态组合（审查 H10 测试盲区实证）。

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

class _StubSessionsIndex implements SessionsIndexSubscription {
  @override
  SessionsIndexState get state => SessionsIndexState();
  @override
  String? get subscriptionId => 'si-seed';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'sessions-index/seed';
  @override
  Future<void> dispose() async {}
}

ComputerStack _stack() {
  final stack = ComputerStack(
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
  return stack;
}

CompanionClient _offlineClient() => CompanionClient.v2(
      config: RelayV2Config(
        endpointOrigin: Uri.parse('http://127.0.0.1:1'),
        deviceSid: 'sid-seed',
      ),
      jwtProvider: () async => null,
    );

const _p1 = {
  'id': 'p-1',
  'hostId': 'local',
  'name': '示例项目',
  'roots': [
    {'rootPath': r'G:\示例项目', 'isPrimary': true},
  ],
  'deleted': false,
};

Map<String, dynamic> _unclassifiedTask(String key) => {
      'taskId': 't-2',
      'title': '无项目任务',
      'workspacePath': key,
      'projectId': null,
      'hostId': 'local',
      'createdAt': 1700000000000,
      'updatedAt': 1700000000000,
    };

void main() {
  late ComputerStack stack;
  late CompanionClient client;

  setUp(() {
    stack = _stack();
    client = _offlineClient();
  });
  tearDown(() async {
    stack.dispose();
    await client.dispose();
  });

  void seed({
    Map<String, dynamic> workspace = const {
      'workspacePath': r'G:\示例项目',
      'label': '示例项目',
      'kind': 'local',
    },
    List<Map<String, dynamic>> projects = const [_p1],
    List<Map<String, dynamic>> tasks = const [],
  }) {
    stack.debugSeedProjectWorkspaceForTest(
      workspace: workspace,
      seedProjects: projects,
      seedTasks: tasks,
      bridge: _StubBridge(),
      sessionsIndex: _StubSessionsIndex(),
      client: client,
    );
  }

  test('H10 核心：P→任务→点回 P，选中恢复（修复前=停在伪项目）', () async {
    seed();
    expect(stack.activeProjectId, 'p-1', reason: '种子稳态=派生选中 p-1');

    stack.switchToConversations();
    expect(stack.activeProjectId, conversationsPseudoProjectId);

    await stack.switchToProject(const {'id': 'p-1', 'name': '示例项目'});
    expect(
      stack.activeProjectId,
      'p-1',
      reason: 'H10：幂等门命中时须恢复显式选中（桥活着≠视图在项目上）',
    );
    expect(stack.sidebarEntries().map((e) => e['id']), contains('p-1'));
  });

  test('backlog 35：派生选中（K 任务归属 X）不得骗过幂等门', () async {
    // 稳态：桥开在 C:\temp（目录 K），该键任务归属 p-1 → 派生
    // activeProjectId=p-1、explicit 空。点项目 p-1：修复前门①被派生值
    // 骗过裸返回（桥留在 K 的 scope——新建任务会落错目录）；修复后
    // 必须拆桥真实重开项目桥（离线客户端重开失败属预期，只验"门没跳"）。
    seed(
      workspace: const {
        'workspacePath': r'C:\temp',
        'label': '默认工作区',
        'kind': 'local',
      },
      tasks: [
        {..._unclassifiedTask(r'C:\temp'), 'projectId': 'p-1'},
      ],
    );
    expect(stack.activeProjectId, 'p-1', reason: '键下任务归属 p-1 → 派生选中');
    expect(stack.bridge, isNotNull);

    final pending = stack.switchToProject(_p1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      stack.bridge,
      isNull,
      reason: 'backlog 35：派生选中≠桥在项目目录——必须拆桥重开（scope 纠正）',
    );
    // 离线客户端的 openBridge 走中继重连节奏（60s 超时级），不等待其
    // 完成：dispose 打断（isGone 短路），失败在 _openActiveWorkspace
    // 内部吞掉，不产生未处理异步错误。
    stack.dispose();
    pending.ignore();
  });

  test('任务→任务：已显式选中时幂等（不重复通知）', () {
    seed();
    stack.switchToConversations();
    final before = stack.activeProjectId;
    var notifications = 0;
    stack.addListener(() => notifications++);
    stack.switchToConversations();
    expect(stack.activeProjectId, before);
    expect(notifications, 0, reason: '显式选中已就位=纯幂等跳过');
  });

  test('H10 窄路径：派生伪项目→点「任务」补显式，readTree 重拉不翻回', () {
    // 稳态=分类任务工作区但键下只剩未归类行（explicit 空 → 派生伪项目）。
    seed(
      workspace: const {
        'workspacePath': r'C:\temp',
        'label': '默认工作区',
        'kind': 'local',
      },
      tasks: [_unclassifiedTask(r'C:\temp')],
    );
    expect(
      stack.activeProjectId,
      conversationsPseudoProjectId,
      reason: '未归类键派生=伪项目（explicit 空）',
    );

    stack.switchToConversations(); // 修复前：裸返回不补显式

    // 模拟 readTree 重拉（种子缝重入=同代码路径 _refreshActiveProject）：
    // 该任务被归入 p-1 → 派生值翻成 p-1。
    seed(
      workspace: const {
        'workspacePath': r'C:\temp',
        'label': '默认工作区',
        'kind': 'local',
      },
      tasks: [
        {..._unclassifiedTask(r'C:\temp'), 'projectId': 'p-1'},
      ],
    );
    expect(
      stack.activeProjectId,
      conversationsPseudoProjectId,
      reason: '点过「任务」=显式选中，readTree 派生变化不得翻回视图',
    );
  });
}
