import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/channel_client.dart' show Channels;
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/transport/relay_client.dart'
    show RelayFailure, RelayState;
import 'package:zcode_pocket/transport/relay_v2.dart';

import 'fake_relay_v2.dart';

/// 工作区项目树（ 工作区列表修复）：
/// - 纯函数层（project_tree.dart）对照官方契约
/// （官方最新源码快照 services/src/project-storage/contract.ts:30-65）；
/// - openBridge 的 project intent 线上载荷（对照 shared/src/validation.ts
///   :258-286 的互斥与字段约束）走 FakeRelayV2 全链路验证。
void main() {
  const timing = RelayV2Timing(
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

  // 官方 ProjectTree 夹具（VirtualProject/ProjectTask 字段样例）。
  final tree = <String, dynamic>{
    'projects': [
      {
        'id': 'p-2',
        'hostId': 'local',
        'name': '示例项目',
        'nameOverridden': false,
        'roots': [
          {'rootPath': r'G:\示例项目', 'position': 0, 'isPrimary': true},
        ],
        'position': 1,
        'pinned': false,
        'deleted': false,
        'createdAt': 1700000000000,
        'updatedAt': 1700000000000,
      },
      {
        'id': 'p-1',
        'hostId': 'local',
        'name': 'Demo App',
        'nameOverridden': true,
        'roots': [
          {'rootPath': r'G:\Demo App', 'position': 0, 'isPrimary': true},
          {'rootPath': r'G:\Demo App\sub', 'position': 1, 'isPrimary': false},
        ],
        'position': 0,
        'pinned': true,
        'deleted': false,
        'createdAt': 1600000000000,
        'updatedAt': 1600000000000,
      },
      {
        'id': 'p-dead',
        'hostId': 'local',
        'name': '已删项目',
        'nameOverridden': false,
        'roots': const [],
        'position': 2,
        'pinned': false,
        'deleted': true,
        'createdAt': 1500000000000,
        'updatedAt': 1500000000000,
      },
    ],
    'tasks': [
      {
        'taskId': 't-1',
        'title': 'Demo App 任务',
        'workspacePath': r'G:\Demo App',
        'workspaceIdentity': 'identity://zcode-app',
        'projectId': 'p-1',
        'hostId': 'local',
        'createdAt': 1700000000000,
        'updatedAt': 1700000000000,
      },
      {
        'taskId': 't-2',
        'title': '无项目任务',
        'workspacePath': r'C:\temp',
        'projectId': null,
        'hostId': 'local',
        'createdAt': 1700000000000,
        'updatedAt': 1700000000000,
      },
    ],
    'deletedTasks': const [],
  };

  group('parseProjectTree', () {
    test('宽松解析：非 Map/缺键 → 空结果', () {
      final a = parseProjectTree(null);
      expect(a.projects, isEmpty);
      expect(a.tasks, isEmpty);
      final b = parseProjectTree(<String, dynamic>{});
      expect(b.projects, isEmpty);
      expect(b.tasks, isEmpty);
      final c = parseProjectTree(<String, dynamic>{
        'projects': 'not-a-list',
        'tasks': [1, 2],
      });
      expect(c.projects, isEmpty);
      expect(c.tasks, isEmpty);
    });

    test('projects/tasks 原样保留（含 deleted）', () {
      final parsed = parseProjectTree(tree);
      expect(parsed.projects.length, 3);
      expect(parsed.tasks.length, 2);
      expect(parsed.projects[2]['deleted'], true);
    });
  });

  group('visibleProjectsOf', () {
    test('剔除 deleted，position 升序', () {
      final visible = visibleProjectsOf(parseProjectTree(tree).projects);
      expect(visible.map((p) => p['id']), ['p-1', 'p-2']);
    });

    test('position 缺省排最后，同位按名', () {
      final visible = visibleProjectsOf([
        {'id': 'a', 'name': 'b', 'position': 5},
        {'id': 'b', 'name': 'a'},
        {'id': 'c', 'name': 'z', 'position': 5},
      ]);
      // 同 position=5：a(name b) 先于 c(name z)；b 无 position 排最后。
      expect(visible.map((p) => p['id']).toList(), ['a', 'c', 'b']);
    });
  });

  group('projectIntentOf / primaryRootOf', () {
    test('intent：id+hostId 透传；hostId 缺席省略', () {
      expect(projectIntentOf(parseProjectTree(tree).projects[0]), {
        'projectId': 'p-2',
        'hostId': 'local',
      });
      expect(projectIntentOf({'id': 'p-9'}), {'projectId': 'p-9'});
    });

    test('primaryRoot：isPrimary 优先，否则首个 root', () {
      final projects = parseProjectTree(tree).projects;
      expect(primaryRootOf(projects[0]), r'G:\示例项目');
      expect(primaryRootOf(projects[1]), r'G:\Demo App');
      expect(primaryRootOf({'id': 'x', 'roots': null}), isNull);
      expect(primaryRootOf({'id': 'x'}), isNull);
    });
  });

  group('projectForWorkspaceKey', () {
    late final parsed = parseProjectTree(tree);
    late final projects = visibleProjectsOf(parsed.projects);
    late final tasks = parsed.tasks;

    test('identity 命中任务归属 → 项目', () {
      final p = projectForWorkspaceKey(
        projects: projects,
        tasks: tasks,
        key: 'identity://zcode-app',
      );
      expect(p?['id'], 'p-1');
    });

    test('路径命中任务归属（无 identity 行）', () {
      final p = projectForWorkspaceKey(
        projects: projects,
        tasks: tasks,
        key: r'G:\示例项目',
      );
      expect(p?['id'], 'p-2'); // 无任务行 → roots 路径兜底
    });

    test('未归类任务（projectId=null）不误配，继续找 roots', () {
      final p = projectForWorkspaceKey(
        projects: projects,
        tasks: tasks,
        key: r'C:\temp',
      );
      expect(p, isNull);
    });

    test('无命中 → null', () {
      expect(
        projectForWorkspaceKey(projects: projects, tasks: tasks, key: 'x'),
        isNull,
      );
    });

    test('③ tie-break：同键多归属取 updatedAt 最新（确定性，修复前红=数组序）',
        () {
      final projects = [
        {'id': 'p-a', 'name': 'A', 'roots': const []},
        {'id': 'p-b', 'name': 'B', 'roots': const []},
      ];
      final tasks = [
        {
          'taskId': 't-old',
          'workspacePath': r'G:\shared',
          'projectId': 'p-a',
          'updatedAt': 1000,
        },
        {
          'taskId': 't-new',
          'workspacePath': r'G:\shared',
          'projectId': 'p-b',
          'updatedAt': 2000,
        },
      ];
      expect(
        projectForWorkspaceKey(
              projects: projects,
              tasks: tasks,
              key: r'G:\shared',
            )?['id'],
        'p-b',
        reason: '最新更新的任务行归属赢（数组序反转也应得 p-b）',
      );
      expect(
        projectForWorkspaceKey(
              projects: projects,
              tasks: tasks.reversed.toList(),
              key: r'G:\shared',
            )?['id'],
        'p-b',
        reason: '行序无关——原实现取首个会随 readTree 行序漂移',
      );
    });
  });

  group('openBridge project intent（FakeRelayV2 全链路）', () {
    test('互斥防护：project+taskId 抛 ArgumentError', () {
      final client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: Uri.parse('http://127.0.0.1:1'),
          deviceSid: 'sid-x',
        ),
        jwtProvider: () async => 'jwt',
      );
      addTearDown(client.dispose);
      expect(
        () => client.openBridge(
          'k',
          taskId: 't',
          project: const {'projectId': 'p'},
        ),
        throwsArgumentError,
      );
    });

    test('project 桥：载荷含 intent 无 taskId；ready 桥重建工作区', () async {
      final fake = FakeRelayV2();
      await fake.start();
      addTearDown(() => fake.close());
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final failures = <RelayFailure>[];
      final client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: fake.origin,
          deviceSid: sid,
          deviceName: '测试机',
          appVersion: 'test',
        ),
        jwtProvider: () async => 'jwt-alice',
        timing: timing,
      );
      client.relay.failures.listen(failures.add);
      addTearDown(client.dispose);
      client.connect();
      await client.waitPaired(timeout: const Duration(seconds: 5));
      expect(client.relay.state, RelayState.paired);

      final openFuture = client.openBridge(
        r'G:\示例项目',
        project: const {'projectId': 'p-2', 'hostId': 'local'},
      );
      // 桌面侧：收到 bridge-open，断言 project intent 在场、taskId 缺席。
      final frame = await device.waitFor('data', const Duration(seconds: 3));
      final payload = (frame!['payload'] as Map).cast<String, dynamic>();
      expect(payload['zcode_type'], 'workspace-bridge-open');
      expect(payload['workspaceKey'], r'G:\示例项目');
      expect(payload['project'], {
        'projectId': 'p-2',
        'hostId': 'local',
      });
      expect(payload.containsKey('taskId'), isFalse);
      device.sendPayload({
        'zcode_type': 'workspace-bridge-ready',
        'requestId': payload['requestId'],
        'bridgeSessionId': payload['bridgeSessionId'],
        'bridge': {
          'bridgeSessionId': payload['bridgeSessionId'],
          'kind': 'local',
          'workspaceKey': r'G:\示例项目',
          'workspacePath': r'G:\示例项目',
        },
      });
      final session = await openFuture;
      expect(session.projectIntent, {
        'projectId': 'p-2',
        'hostId': 'local',
      });
      expect(session.workspaceKey, r'G:\示例项目');
      // ready 桥载荷 → activeWorkspace 条目（ComputerStack 同款路径）。
      final ws = workspaceFromBridgePayload(session.bridge, label: '示例项目');
      expect(ws['workspacePath'], r'G:\示例项目');
      expect(projectForWorkspaceKey(
        projects: [
          {'id': 'p-2', 'roots': [
            {'rootPath': r'G:\示例项目'},
          ]},
        ],
        tasks: const [],
        key: r'G:\示例项目',
      )?['id'], 'p-2');
      session.dispose();
    });
  });

  group('未归类任务（默认工作区，v1.1）', () {
    late final tasks = parseProjectTree(tree).tasks;

    test('isUnclassified：projectId 空=未归类；有归属=否', () {
      // 夹具：t-1 属 p-1；t-2 projectId=null（C:\temp 未归类）。
      expect(isUnclassifiedTask(tasks[1]), isTrue);
      expect(isUnclassifiedTask(tasks[0]), isFalse);
      expect(isUnclassifiedTask({'taskId': 'x', 'projectId': 'p'}), isFalse);
      // 无 workspace 键的空行不算。
      expect(isUnclassifiedTask({'taskId': 'x'}), isFalse);
    });

    test('latestUnclassified：取 updatedAt 最大者；空集 null', () {
      final withTwo = [
        ...tasks,
        {
          'taskId': 't-3',
          'title': '更新的未归类',
          'workspacePath': r'C:\temp',
          'projectId': null,
          'updatedAt': 1800000000000,
        },
      ];
      expect(latestUnclassifiedTask(withTwo)?['taskId'], 't-3');
      expect(latestUnclassifiedTask([tasks[0]]), isNull);
    });

    test('unclassifiedTasksOf：跨目录聚合+updatedAt 降序（v1.2 列表页）',
        () {
      final rows = [
        {
          'taskId': 'a',
          'workspacePath': r'C:\demo\.zcode\workspace\default',
          'projectId': null,
          'updatedAt': 100,
        },
        {
          'taskId': 'b',
          'workspacePath':
              r'C:\demo\.zcode\workspace\1792000000000-aaaa-1',
          'projectId': null,
          'updatedAt': 300,
        },
        {
          'taskId': 'c',
          'workspacePath': r'G:\Demo App',
          'projectId': 'p-1',
          'updatedAt': 500,
        },
        {
          'taskId': 'd',
          'workspacePath': r'C:\demo\.zcode\workspace\default',
          'updatedAt': 200,
        },
      ];
      final out = unclassifiedTasksOf(rows);
      expect(out.map((t) => t['taskId']).toList(), ['b', 'd', 'a']);
    });

    test('「任务」伪项目条目（官方 conversationsSection=任务）', () {
      final p = conversationsPseudoProject();
      expect(p['id'], conversationsPseudoProjectId);
      expect(p['name'], '任务');
    });
  });

  group('overlayLivePhase（2026-10-26 真机验收②：聚合视图实时状态覆盖）', () {
    test('活卡有该任务的 phase → 覆盖 displayStatus（运行中不再显示完成）', () {
      final rows = [
        {
          'taskId': 'session_a',
          'title': '示例任务',
          'workspacePath': r'D:\示例工作区\default',
          'projectId': null,
          'status': 'completed',
          'updatedAt': 100,
        },
      ];
      final out = overlayLivePhase(rows, {'session_a': 'running'});
      expect(out.single['displayStatus'], 'running',
          reason: 'readTree 持久 completed 被实时 running 覆盖——'
              '修复前聚合视图恒显示上回合"完成"');
      // 原行不被原地修改（渲染层复用入参列表的场景安全）。
      expect(rows.single.containsKey('displayStatus'), isFalse);
    });

    test('无实时订阅的任务维持持久值；活卡 completed 同样覆盖（更新即真相）', () {
      final rows = [
        {'taskId': 'session_a', 'status': 'completed'},
        {'taskId': 'session_b', 'status': 'completed'},
      ];
      final out = overlayLivePhase(rows, {'session_b': 'completedSuccess'});
      expect(out.first.containsKey('displayStatus'), isFalse,
          reason: '跨工作区无实时数据=诚实显示持久值');
      expect(out.last['displayStatus'], 'completedSuccess');
    });

    test('taskId 缺失/空串行不参与覆盖（不误命中空键）', () {
      final rows = [
        {'title': '无 id 行', 'status': 'completed'},
      ];
      final out = overlayLivePhase(rows, {'': 'running'});
      expect(out.single.containsKey('displayStatus'), isFalse);
    });
  });

  group('openBridge task intent（FakeRelayV2 全链路，v1.1）', () {
    test('互斥防护：taskHostId 缺 taskId 抛错；project+taskHostId 抛错', () {
      final client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: Uri.parse('http://127.0.0.1:1'),
          deviceSid: 'sid-x',
        ),
        jwtProvider: () async => 'jwt',
      );
      addTearDown(client.dispose);
      expect(
        () => client.openBridge('k', taskHostId: 'local'),
        throwsArgumentError,
      );
      expect(
        () => client.openBridge(
          'k',
          taskId: 't',
          taskHostId: 'local',
          project: const {'projectId': 'p'},
        ),
        throwsArgumentError,
      );
    });

    test('任务桥：taskId+taskHostId 上行，intent 随 session 携带', () async {
      final fake = FakeRelayV2();
      await fake.start();
      addTearDown(() => fake.close());
      final sid = fake.registerDevice('jwt-alice');
      final device = await fake.connectDevice(sid);
      addTearDown(device.close);

      final client = CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: fake.origin,
          deviceSid: sid,
          deviceName: '测试机',
          appVersion: 'test',
        ),
        jwtProvider: () async => 'jwt-alice',
        timing: timing,
      );
      addTearDown(client.dispose);
      client.connect();
      await client.waitPaired(timeout: const Duration(seconds: 5));

      final openFuture = client.openBridge(
        'identity://conv',
        taskId: 'sess-task-1',
        taskHostId: 'local',
      );
      final frame = await device.waitFor('data', const Duration(seconds: 3));
      final payload = (frame!['payload'] as Map).cast<String, dynamic>();
      expect(payload['zcode_type'], 'workspace-bridge-open');
      expect(payload['taskId'], 'sess-task-1');
      expect(payload['taskHostId'], 'local');
      expect(payload.containsKey('project'), isFalse);
      device.sendPayload({
        'zcode_type': 'workspace-bridge-ready',
        'requestId': payload['requestId'],
        'bridgeSessionId': payload['bridgeSessionId'],
        'bridge': {
          'bridgeSessionId': payload['bridgeSessionId'],
          'kind': 'local',
          'workspaceKey': r'C:\users\zcode\conversations',
          'workspacePath': r'C:\users\zcode\conversations',
          'initialTaskId': 'sess-task-1',
        },
      });
      final session = await openFuture;
      expect(session.taskIntent, {
        'taskId': 'sess-task-1',
        'taskHostId': 'local',
      });
      expect(session.projectIntent, isNull);
      expect(session.initialTaskId, 'sess-task-1');
      session.dispose();
    });
  });

  test('Channels.project 与官方 ServiceChannels.Project 一致', () {
    expect(Channels.project, 'project');
  });
}
