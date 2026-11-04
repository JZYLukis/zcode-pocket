import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/interaction_banner.dart' as banner;
import 'package:zcode_pocket/ui/task_home.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

/// parity-fix-1（2026-10-29 差异审查修复批）纯逻辑回归：
/// B7 运行优先排序/B10 复制带计划/B11 时间线四类标记/B4 artifact 兜底/
/// B30 八档时间分桶/B2 自定义答案合并/A6 edit 档/A3 查询确权载荷。

void main() {
  group('B7 任务主页排序（running-first+稳定决胜）', () {
    final now = DateTime(2026, 10, 29, 12);
    final t = (int minutesAgo) =>
        now.subtract(Duration(minutes: minutesAgo)).millisecondsSinceEpoch;
    List<Map<String, dynamic>> items() => [
      {
        'taskId': 'a',
        'title': '完成的旧任务',
        'homeUpdatedAt': t(30),
        'homeStatus': 'completed',
        'homePinned': false,
        'homeGroupKey': 'g',
        'homeGroupOrder': 1,
        'homeGroupTitle': '项目',
      },
      {
        'taskId': 'b',
        'title': '运行中任务',
        'homeUpdatedAt': t(60),
        'homeStatus': 'running',
        'homePinned': false,
        'homeGroupKey': 'g',
        'homeGroupOrder': 1,
        'homeGroupTitle': '项目',
      },
      {
        'taskId': 'c',
        'title': '完成的新任务',
        'homeUpdatedAt': t(10),
        'homeStatus': 'completed',
        'homePinned': false,
        'homeGroupKey': 'g',
        'homeGroupOrder': 1,
        'homeGroupTitle': '项目',
      },
    ];

    test('运行中置顶；同层按时间倒序；同分同值不换位', () {
      final out = buildTaskHomeItems(
        rows: items(),
        mode: TaskHomeMode.recent,
        collapsedGroups: const {},
        now: now,
      );
      final tasks = out
          .whereType<TaskHomeItem>()
          .where((e) => e.kind == TaskHomeItemKind.task)
          .map((e) => e.task!)
          .toList();
      // 分桶内：今天桶中 running 在最前（跨桶顺序由分桶决定）。
      final today = tasks
          .where((t) => taskHomeTimeBucket(t['homeUpdatedAt'] as int, now) == '今天')
          .toList();
      expect(today.first['taskId'], 'b', reason: '运行中任务置顶');
      // 稳定决胜：同 updatedAt 的两条按 taskId 升序（确定性）。
      final rows = [
        ...items(),
        {
          'taskId': 'a0',
          'title': '同值',
          'homeUpdatedAt': t(30),
          'homeStatus': 'completed',
          'homePinned': false,
          'homeGroupKey': 'g',
          'homeGroupOrder': 1,
          'homeGroupTitle': '项目',
        },
      ];
      final out2 = buildTaskHomeItems(
        rows: rows,
        mode: TaskHomeMode.recent,
        collapsedGroups: const {},
        now: now,
      );
      final ids = out2
          .whereType<TaskHomeItem>()
          .where((e) => e.kind == TaskHomeItemKind.task)
          .map((e) => '${e.task!['taskId']}')
          .toList();
      expect(ids.indexOf('a') < ids.indexOf('a0'), isTrue,
          reason: '同 updatedAt 时 taskId 决胜保证确定性');
    });
  });

  group('B30 时间分桶（18077 验收#9 用户拍板四组口径，取代官方八档）', () {
    final now = DateTime(2026, 10, 29, 12); // 周四
    int at(DateTime d) =>
        DateTime(d.year, d.month, d.day, 10).millisecondsSinceEpoch;

    test('今天/昨天/本周/以前（四组：前天归本周，上周月档全归以前）', () {
      // 10-29 是周四；本周一=10-26。
      expect(taskHomeTimeBucket(at(DateTime(2026, 10, 29)), now), '今天');
      expect(taskHomeTimeBucket(at(DateTime(2026, 10, 28)), now), '昨天');
      expect(taskHomeTimeBucket(at(DateTime(2026, 10, 27)), now), '本周');
      expect(taskHomeTimeBucket(at(DateTime(2026, 10, 26)), now), '本周');
      expect(taskHomeTimeBucket(at(DateTime(2026, 10, 23)), now), '以前');
      expect(taskHomeTimeBucket(at(DateTime(2026, 10, 12)), now), '以前');
      expect(taskHomeTimeBucket(at(DateTime(2026, 8, 30)), now), '以前');
      expect(taskHomeTimeBucket(0, now), '以前');
    });
  });

  group('B10/B11/B4 行投影', () {
    List<ChatItem> build(List<Map<String, dynamic>> rows) =>
        buildChatItems(rows);

    test('B10 复制整轮追加 ExitPlanMode 计划 markdown', () {
      final items = build([
        {
          'rowId': 1,
          'kind': 'turnHeader',
          'createdAt': 1,
          'state': 'complete',
        },
        {
          'rowId': 2,
          'kind': 'assistantText',
          'text': '方案如下',
          'state': 'complete',
        },
        {
          'rowId': 3,
          'kind': 'toolCall',
          'name': 'ExitPlanMode',
          'toolName': 'ExitPlanMode',
          'status': 'complete',
          'input': {'plan': '# 计划正文'},
        },
      ]);
      final work = items.whereType<TurnBarItem>().single;
      expect(work.work.allTextJoined, contains('# 计划正文'));
    });

    test('B10 计划正文已在正文段时不重复追加', () {
      final items = build([
        {'rowId': 1, 'kind': 'turnHeader', 'createdAt': 1, 'state': 'complete'},
        {
          'rowId': 2,
          'kind': 'assistantText',
          'text': '# 计划正文',
          'state': 'complete',
        },
        {
          'rowId': 3,
          'kind': 'toolCall',
          'name': 'ExitPlanMode',
          'toolName': 'ExitPlanMode',
          'status': 'complete',
          'input': {'plan': '# 计划正文'},
        },
      ]);
      final work = items.whereType<TurnBarItem>().single;
      expect('# 计划正文'.allMatches(work.work.allTextJoined).length, 1);
    });

    test('B11 compact/forkNotice/goalVerify 标记渲染（含 running 态）', () {
      final items = build([
        {'rowId': 1, 'kind': 'turnHeader', 'createdAt': 1, 'state': 'complete'},
        {
          'rowId': 2,
          'kind': 'timelineMarker',
          'marker': {'type': 'compact', 'origin': 'auto', 'status': 'running'},
        },
        {
          'rowId': 3,
          'kind': 'timelineMarker',
          'marker': {'type': 'forkNotice', 'parentSessionId': 'p', 'parentRowId': 1},
        },
        {
          'rowId': 4,
          'kind': 'timelineMarker',
          'marker': {'type': 'goalVerify', 'iteration': 2, 'outcome': 'pass'},
        },
        {
          'rowId': 5,
          'kind': 'timelineMarker',
          'marker': {'type': 'modelChange', 'fromModel': 'a', 'toModel': 'b'},
        },
      ]);
      final markers = items.whereType<TimelineMarkerItem>().toList();
      expect(markers, hasLength(4), reason: '四类标记全部渲染（此前只 modelChange）');
      // compact-command-1：文案对齐官方 zh-CN（contextCompaction.started）。
      expect(markers[0].label, '正在压缩上下文');
      expect(markers[0].running, isTrue);
      expect(markers[1].label, '本会话由分支创建');
      expect(markers[2].label, contains('第 2 次迭代'));
      expect(markers[2].label, contains('目标已完成，任务结束'));
      expect(markers[3].label, contains('模型已切换'));
    });

    // 开源审查 B2-1（lane 语义，官方 product-projection.ts:4943-4945/
    // 5015）：compact=assistantWork——marker 归属事件到达时的行尾。
    // auto-compact mid-turn 插入时落在当前回合内部，此前一律 closeTurn
    // 会把运行中轮劈成两半（文件卡提前投出、后续工作行成无头段假
    // 「已处理」）。
    test('开源审查 B2-1：assistantWork lane 的 compact marker mid-turn 落回合内部（不劈轮）', () {
      final items = build([
        {'rowId': 1, 'kind': 'turnHeader', 'createdAt': 1, 'state': 'running'},
        {'rowId': 2, 'kind': 'userInput', 'text': '问'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'success', 'text': '前半'},
        {
          'rowId': 4,
          'kind': 'timelineMarker',
          'lane': 'assistantWork',
          'marker': {'type': 'compact', 'origin': 'auto', 'status': 'success'},
        },
        {
          'rowId': 5,
          'kind': 'toolCall',
          // 非 Bash：Bash+空 inputText 在流式期被投影延后（官方语义），
          // 会干扰「marker 后续工作行归属」断言。
          'toolName': 'Read',
          'status': 'running',
        },
      ]);
      expect(
        items.whereType<TimelineMarkerItem>(),
        isEmpty,
        reason: 'mid-turn compact 不出顶层分隔线（不 closeTurn）',
      );
      final turns = items.whereType<TurnBarItem>().toList();
      expect(turns, hasLength(1), reason: '运行中轮不被 marker 劈成两段');
      final rowIds = turns[0].work.work.map((r) => r['rowId']).toList();
      expect(
        rowIds,
        containsAll([3, 4, 5]),
        reason: 'marker 行按官方 lane 归属回合内部（事件到达时的行尾）',
      );
      expect(turns[0].work.header?['state'], 'running',
          reason: '轮保持运行态（修复前 marker 后工作行成无头段假「已处理」）');
    });

    test('开源审查 B2-1 对照：turnTailBoundary lane 与缺 lane 的 marker 仍关轮+顶层分隔线', () {
      final items = build([
        {'rowId': 1, 'kind': 'turnHeader', 'createdAt': 1, 'state': 'completedSuccess'},
        {'rowId': 2, 'kind': 'userInput', 'text': '问'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'success', 'text': '正文'},
        {
          'rowId': 4,
          'kind': 'timelineMarker',
          'lane': 'turnTailBoundary',
          'marker': {'type': 'goalVerify', 'iteration': 1, 'outcome': 'pass'},
        },
      ]);
      expect(
        items.whereType<TimelineMarkerItem>(),
        hasLength(1),
        reason: '轮边界 lane（goalVerify/modelChange/forkNotice）维持现行为',
      );
    });

    test('B4 artifact 行进工作段不再丢弃', () {
      final items = build([
        {'rowId': 1, 'kind': 'turnHeader', 'createdAt': 1, 'state': 'complete'},
        {
          'rowId': 2,
          'kind': 'artifact',
          'displayName': '产物 A',
          'artifactType': 'file',
          'state': 'current',
        },
      ]);
      final work = items.whereType<TurnBarItem>().single;
      expect(
        work.work.work.any((r) => r['kind'] == 'artifact'),
        isTrue,
        reason: 'artifact 行此前落 default 静默丢弃',
      );
    });
  });

  group('B2 提问自定义答案合并（官方 customAnswer 对位）', () {
    final questions = [
      {
        'question': '选择方案',
        'multiSelect': false,
        'options': [
          {'value': 'a', 'label': 'A'},
          {'value': 'b', 'label': 'B'},
        ],
      },
      {
        'question': '多选',
        'multiSelect': true,
        'options': [
          {'value': 'x', 'label': 'X'},
          {'value': 'y', 'label': 'Y'},
        ],
      },
    ];

    test('单选：自定义顶替选项；多选：与选项并存', () {
      final content = banner.buildQuestionsResponseContent(
        questions,
        {1: {'x'}},
        custom: {0: '第三方案', 1: '外加项'},
      );
      expect(content['answer_0'], '第三方案', reason: '单选自定义顶替选项选择');
      expect(content['answer_1'], ['x', '外加项'], reason: '多选=选项+自定义');
      expect(
        (content['answers'] as Map)['选择方案'],
        '第三方案',
      );
    });

    test('仅自定义也可提交（不选任何选项）；单题时兼容字段照常', () {
      final content = banner.buildQuestionsResponseContent(
        questions,
        const {},
        custom: {0: '只要自定义'},
      );
      expect(content['answer_0'], '只要自定义');
      expect(content.containsKey('answer'), isFalse,
          reason: '两题场景不产单题兼容键');
      final single = banner.buildQuestionsResponseContent(
        questions.take(1).toList(),
        const {},
        custom: {0: '只要自定义'},
      );
      expect(single['answer'], '只要自定义', reason: '单题兼容字段照常');
    });
  });

  group('A6/A3 传输层', () {
    test('A6 模式目录含 edit（自动编辑）', () async {
      final channel = _ParityChannel();
      final bridge = _ParityBridge(channel);
      final conv = ConversationTransport(
        session: bridge,
        scope: const {'workspacePath': r'C:\demo'},
      );
      final prep = await conv.prepareWorkspace();
      final modeOption = prep.configOptions
          .firstWhere((o) => o.id == 'mode');
      expect(
        modeOption.options.any((o) => o.value == 'edit'),
        isTrue,
        reason: '官方可切换子集含 edit——此前硬编码缺该档',
      );
    });

    test('A3 queryConversationCommand 载荷与结果解析', () async {
      final channel = _ParityChannel();
      final bridge = _ParityBridge(channel);
      final conv = ConversationTransport(
        session: bridge,
        scope: const {'workspacePath': r'C:\demo'},
      );
      final result = await conv.queryConversationCommand(
        commandId: 'cmd-1',
        sessionId: 's-1',
      );
      expect(channel.lastQuery, {
        'workspacePath': r'C:\demo',
        'commands': [
          {'sessionId': 's-1', 'commandId': 'cmd-1'},
        ],
      }, reason: '官方形状=workspace 目标平铺+commands（review-fix-1 A1：'
          '此前缺 scope，host resolveWorkspaceKey 路由必败=真机死路径）');
      expect(result, {'status': 'accepted'}, reason: 'results[0].result 透传');
      expect(conv.lastCommandIdOf('s-1'), isNull, reason: '未发命令时无记录');
    });
  });
}

class _ParityChannel extends ChannelClient {
  _ParityChannel() : super(sendBody: (_) {});
  Map<String, dynamic>? lastQuery;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'readWorkspacePresentation':
        return {
          'mode': 'build',
          'slashCommands': const <dynamic>[],
        };
      case 'queryConversationCommandsV4':
        lastQuery = (args.first as Map).cast<String, dynamic>();
        return {
          'results': [
            {
              'key': {
                'sessionId': 's-1',
                'commandId': 'cmd-1',
              },
              'result': {'status': 'accepted'},
            },
          ],
        };
      case 'handshakeV4':
        return {'ok': true};
      default:
        return <String, dynamic>{};
    }
  }
}

class _ParityBridge implements BridgeSession {
  _ParityBridge(this.channel);
  final _ParityChannel channel;

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
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-parity';
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
