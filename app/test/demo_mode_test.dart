// 演示模式单测：
// 1) ZP_DEMO 编译期开关的解析语义（String 语义宽容 '1'/'true'——
//    bool.fromEnvironment 只认字面 'true' 的教训与 VOICE_HMS 同源）；
// 2) DemoChannel/DemoScript 在通道层驱动真实 ConversationTransport：
//    订阅 ack→快照帧、si/tasks-index 投影落位；
// 3) 流式重放时间线：sendText → 行追加/打字机 delta → 审批卡 →
//    裁决 → 收尾（fake_async 驱动脚本定时器）；
// 4) DemoAppState 门面：单电脑档案/在线相位/工作区与桥注入。
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/demo/demo_app_state.dart';
import 'package:zcode_pocket/demo/demo_bridge.dart';
import 'package:zcode_pocket/demo/demo_data.dart';
import 'package:zcode_pocket/demo/demo_mode.dart';
import 'package:zcode_pocket/demo/demo_script.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/link_phase.dart';
import 'package:zcode_pocket/transport/conversation.dart';

void main() {
  group('ZP_DEMO 编译期开关解析', () {
    test('String 语义：仅 1/true 视为开启', () {
      expect(demoModeEnabled, isFalse); // 测试构建不带 define
    });

    test('宽容解析钉死（bool.fromEnvironment 不认 1 的教训）', () {
      // 直接编译 const 不可翻转，用同源逻辑钉语义：定义形态与
      // demo_mode.dart 完全一致地内联断言。
      bool parse(String v) => v == '1' || v == 'true';
      expect(parse(''), isFalse);
      expect(parse('0'), isFalse);
      expect(parse('false'), isFalse);
      expect(parse('TRUE'), isFalse); // 大小写敏感，与生产常量一致
      expect(parse('1'), isTrue);
      expect(parse('true'), isTrue);
    });
  });

  group('通道层：真实传输跑在演示脚本上', () {
    late DemoBridge bridge;
    late DemoScript script;
    late ConversationTransport conv;

    setUp(() {
      bridge = DemoBridge();
      script = DemoScript(bridge);
      conv = ConversationTransport(session: bridge, scope: demoWorkspace);
    });

    tearDown(() {
      script.dispose();
      bridge.dispose();
    });

    Future<void> until(bool Function() cond) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!cond()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('等待条件超时');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('会话订阅：ack→快照帧→状态落位（旗舰会话）', () async {
      final sub = await conv.subscribe('t-menu-fix');
      // 快照帧在 ack 后 250ms 推送——轮询等待。
      await until(() => sub.state.ready);
      expect(sub.state.rows, isNotEmpty);
      expect(sub.state.rows.any((r) => r['kind'] == 'toolCall'), isTrue,
          reason: '历史应含工具行');
      expect(sub.state.rows.any((r) => r['kind'] == 'subagent'), isTrue,
          reason: '历史应含子代理行');
      final snap = sub.state.snapshot;
      expect('${snap?['control']?['phase']}', 'completedSuccess');
      expect(sub.state.logEpoch, 'demo-e1');
      await sub.dispose();
    });

    test('si 订阅：sessions 投影就绪', () async {
      final sub = await conv.subscribeSessionsIndex(maxAttempts: 1);
      await until(() => sub.state.ready);
      expect(sub.state.sessions.length, greaterThanOrEqualTo(10),
          reason: '演示任务全部有条目');
      await sub.dispose();
    });

    test('tasks-index 订阅：快照整表落位', () async {
      final sub = await conv.subscribeTasksIndex();
      await until(() => sub.state.hasSnapshot);
      expect(sub.state.rows.length, greaterThanOrEqualTo(10));
      final running = sub.state.rows.values
          .where((r) => '${r['liveStatus']}' == 'running')
          .toList();
      expect(running, isNotEmpty, reason: '应有运行中任务（首页 spinner 源）');
      await sub.dispose();
    });

    test('审批卡静态在场：运行中会话的 pendingInteractions', () async {
      final sub = await conv.subscribe('t-chart-dark');
      await until(() => sub.state.ready);
      final pending = sub.state.snapshot?['pendingInteractions'];
      expect(pending, isA<List>().having((l) => l.length, 'length', 1));
      expect(
        (pending as List).first is Map &&
            '${pending.first['payload']['kind']}' == 'permission',
        isTrue,
      );
      await sub.dispose();
    });
  });

  group('流式重放时间线（fake_async 驱动脚本定时器）', () {
    test('sendText → 行追加 → 打字机 → 审批 → 允许 → 完成', () {
      fakeAsync((async) async {
        final bridge = DemoBridge();
        final script = DemoScript(bridge);
        final conv = ConversationTransport(session: bridge, scope: demoWorkspace);

        // 新建会话 + 订阅。
        final sid = await conv.createSession(
          demoWorkspacePath,
          firstText: '给 Header 组件加滚动吸顶',
        );
        final sub = await conv.subscribe(sid);
        async.elapse(const Duration(milliseconds: 500));
        expect(sub.state.ready, isTrue, reason: '空会话快照就绪');

        // 发送消息：accepted 后脚本重放。
        await conv.sendText(sid, '给 Header 组件加滚动吸顶');
        // 用户消息 + 回合头 + 思考 + 读文件 + 正文打字机。
        async.elapse(const Duration(seconds: 4));
        final rows = sub.state.rows;
        expect(
          rows.any((r) =>
              r['kind'] == 'userInput' &&
              '${r['text']}'.contains('Header')),
          isTrue,
          reason: '用户消息经帧上屏',
        );
        expect(rows.any((r) => r['kind'] == 'reasoning'), isTrue);
        expect(rows.any((r) => r['kind'] == 'toolCall'), isTrue);
        expect(rows.any((r) => r['kind'] == 'assistantText'), isTrue,
            reason: '打字机正文行');
        final streamed = rows
            .where((r) => r['kind'] == 'assistantText')
            .map((r) => '${r['text']}')
            .join();
        expect(streamed, contains('NotificationListener'),
            reason: '打字机增量已累积');

        // 审批卡出现（9.2s 节拍）。
        async.elapse(const Duration(seconds: 6));
        final pending = sub.state.snapshot?['pendingInteractions'];
        expect(pending, isA<List>().having((l) => l.length, 'length', 1),
            reason: 'Bash 权限请求在场');

        // 裁决：允许 → 测试通过 → 总结收尾。
        await conv.resolveInteraction(sid, 'ia-live', optionId: 'allow');
        async.elapse(const Duration(seconds: 4));
        expect(
          '${sub.state.snapshot?['control']?['phase']}',
          'completedSuccess',
          reason: '允许后回合完成',
        );
        expect(
          sub.state.rows
              .any((r) => '${r['kind']}' == 'assistantText' &&
                  '${r['text']}'.contains('吸顶效果完成')),
          isTrue,
          reason: '最终总结在场',
        );

        await sub.dispose();
        async.elapse(const Duration(milliseconds: 100));
        script.dispose();
        bridge.dispose();
      });
    });

    test('拒绝路径：审批 deny → 工具行 error + 中断收尾', () {
      fakeAsync((async) async {
        final bridge = DemoBridge();
        final script = DemoScript(bridge);
        final conv = ConversationTransport(session: bridge, scope: demoWorkspace);

        final sid = await conv.createSession(demoWorkspacePath, firstText: '改配色');
        final sub = await conv.subscribe(sid);
        await conv.sendText(sid, '改配色');
        async.elapse(const Duration(seconds: 10));
        expect(
          sub.state.snapshot?['pendingInteractions'],
          isA<List>().having((l) => l.length, 'length', 1),
        );
        await conv.resolveInteraction(sid, 'ia-live', optionId: 'deny');
        async.elapse(const Duration(seconds: 2));
        expect(
          sub.state.rows
              .any((r) => '${r['error'] ?? ''}'.contains('用户拒绝')),
          isTrue,
          reason: '拒绝后工具行带 error',
        );
        await sub.dispose();
        async.elapse(const Duration(milliseconds: 100));
        script.dispose();
        bridge.dispose();
      });
    });
  });

  group('DemoAppState 门面', () {
    test('单电脑档案/在线相位/桥与传输注入', () async {
      final app = DemoAppState();
      expect(app.loaded, isTrue);
      expect(app.phase, LinkPhase.online);
      expect(app.profiles, hasLength(1));
      expect(app.profiles.single.deviceSid, demoDeviceSid);
      expect(app.activeProfile, isNotNull);
      expect(app.activeAccountLabel, demoAccountLabel);
      expect(app.workspaces, hasLength(1));
      expect(app.bridge, isNotNull);
      expect(app.conversation, isNotNull);

      // 首页数据流落位（si 订阅 + tasks-index 真实链路）。
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!(app.workspaceTasks.isNotEmpty && app.sidebarProjects.isNotEmpty)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('首页数据流未落位：tasks=${app.workspaceTasks.length} '
              'projects=${app.sidebarProjects.length}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(app.workspaceTasks.length, greaterThanOrEqualTo(10));
      expect(app.projectTasks, isNotEmpty, reason: 'readTree 已并入');

      // 会话订阅走真注册表。
      final sub = await app.ensureConversation('t-menu-fix');
      final deadline2 = DateTime.now().add(const Duration(seconds: 3));
      while (!sub.state.ready) {
        if (DateTime.now().isAfter(deadline2)) fail('会话快照超时');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(sub.state.rows, isNotEmpty);

      await sub.dispose();
      app.dispose();
    });

    test('任务操作闭环：已读清除经通道回到 tasks-index', () async {
      final app = DemoAppState();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (app.workspaceTasks.isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('任务列表超时');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // t-export 种子带 unreadAt；markTaskRead → setTaskUnread(false) →
      // 脚本回推 task.upserted（去 unreadAt）→ tasks-index 映射回首页行。
      await app.markTaskRead('t-export');
      final deadline2 = DateTime.now().add(const Duration(seconds: 3));
      bool cleared() => app.workspaceTasks
          .where((t) => '${t['taskId']}' == 't-export')
          .every((t) => t['unreadAt'] == null);
      while (!cleared()) {
        if (DateTime.now().isAfter(deadline2)) {
          fail('未读标记未被增量帧清除');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      app.dispose();
    });
  });

  group('演示数据集完整性', () {
    test('任务 ID 唯一且会话映射稳定', () {
      final rows = demoTasksIndexRows();
      final ids = rows.map((r) => '${r['address']['taskId']}').toSet();
      expect(ids.length, rows.length, reason: 'taskId 不重复');
      // 产品约定：会话键 == taskId（首页点卡以 taskId 直接订阅——曾因
      // 另起 s- 前缀映射导致订阅键与快照键错位、页面恒转圈）。
      final snaps = demoConversationSnapshots();
      for (final id in ids) {
        expect(demoSessionIdOf(id), id);
        expect(snaps, contains(demoSessionIdOf(id)),
            reason: '$id 应有会话快照');
      }
    });

    test('快照骨架字段齐备（window/totalCount/firstRowId 一致）', () {
      final snaps = demoConversationSnapshots();
      expect(snaps, isNotEmpty);
      for (final e in snaps.entries) {
        final rows = (e.value['rows'] as Map)['window'] as List;
        final total = (e.value['rows'] as Map)['totalCount'] as int;
        expect(total, rows.length, reason: '${e.key}: totalCount=行数');
        expect(e.value['control'], isA<Map>(), reason: '${e.key}: control 在场');
        expect(e.value['config'], isA<Map>(), reason: '${e.key}: config 在场');
      }
    });

    test('产物 base64 可解码回原文', () {
      final read = demoWorkflowArtifactRead('run-release-notes', 'art-notes');
      final bytes = base64Decode(read['dataBase64'] as String);
      final text = utf8.decode(bytes);
      expect(text, contains('# v2.4 发布说明'));
      expect(read['mediaType'], 'text/markdown');
    });

    test('热力图 12 周×7 天且跨次运行确定性', () {
      Map<String, dynamic> snapshot() => demoCodingPlanUsageSnapshot('7d');
      final activity = snapshot()['activity'] as Map;
      final heatmap = activity['heatmap'] as Map;
      final list = heatmap['weeks'] as List;
      expect(list.length, 12);
      for (final w in list) {
        expect((w as Map)['days'], hasLength(7));
      }
      // 确定性：两次构造的日粒度令牌完全一致（截图/基线可复现的前提）。
      final a = jsonEncode(list);
      final b = jsonEncode(
          (((snapshot())['activity'] as Map)['heatmap'] as Map)['weeks']);
      expect(b, a);
    });
  });
}
