// 定时任务编辑闭环回归（2026-11-05 反馈⑤：此前只可查看——整卡无
// onTap、菜单无编辑、客户端无 updateAutomation）。锁：整卡点击进编辑
// 页 → 改标题/调度档位 → 保存下发 updateAutomation（scheduleRule 为
// 调度权威 + cronExpr 兼容 + scheduleEditedByUser）→ 返回刷新列表；
// 自定义 cron 档显式置 null 清旧规则（否则旧规则仍是权威、改 cron 不
// 生效）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/automation_page.dart';

class _EditChannel extends ChannelClient {
  _EditChannel() : super(sendBody: (_) {});

  int listCalls = 0;
  Map<String, dynamic>? updateArgs;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'listAllAutomations':
        listCalls++;
 // scheduleRule 是调度权威：每天 09:30（official word-list daily）。
        return [
          {
            'automationId': 'a1',
            'title': '巡检',
            'prompt': '跑一遍构建',
            'cronExpr': '30 9 * * *',
            'enabled': true,
            'recurring': true,
            'lifecycleStatus': 'active',
            'workspacePath': 'G:/Demo App',
            'workspaceIdentity': 'ws1',
            'scheduleRule': {
              'unit': 'daily',
              'interval': 1,
              'hour': 9,
              'minute': 30,
            },
          },
        ];
      case 'updateAutomation':
        updateArgs = (args.first as Map).cast<String, dynamic>();
        return {
          'automationId': 'a1',
          'title': '${updateArgs!['title']}',
          'prompt': '${updateArgs!['prompt']}',
          'cronExpr': '${updateArgs!['cronExpr']}',
          'enabled': true,
          'recurring': true,
          'lifecycleStatus': 'active',
          'workspacePath': 'G:/Demo App',
          'workspaceIdentity': 'ws1',
        };
    }
    return null;
  }
}

class _EditBridge implements BridgeSession {
  _EditBridge(this.channel);

  final _EditChannel channel;

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
  String? get workspaceKey => 'ws1';
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

class _EditApp extends AppState {
  _EditApp(this.channel);

  final _EditChannel channel;

  @override
  BridgeSession? get bridge => _EditBridge(channel);
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspacePath': 'G:/Demo App',
    'workspaceIdentity': 'ws1',
  };
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(theme: buildAppTheme(), home: const AutomationPage()),
);

void main() {
  testWidgets('整卡点击进编辑：改标题+档位保存 → updateAutomation 全载荷 + 刷新', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel();
    await tester.pumpWidget(_host(_EditApp(channel)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('巡检'), findsOneWidget, reason: '列表加载完成');

 // 整卡点击（反馈⑤主诉求：卡片此前完全不可点）。
    await tester.tap(
      find.byKey(const ValueKey('automation-card-tap-a1')).first,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('编辑定时任务'), findsOneWidget, reason: '进入编辑页');
 // scheduleRule 预填：每天档选中、时刻字段带原值。
    expect(
      find.byKey(const ValueKey('automation-sched-daily')),
      findsOneWidget,
    );

 // 改标题 → 保存。
    await tester.enterText(
      find.byKey(const ValueKey('automation-edit-title')),
      '每日巡检（改）',
    );
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final args = channel.updateArgs;
    expect(args, isNotNull, reason: '保存必须调用 updateAutomation');
    expect(args!['automationId'], 'a1');
    expect(args['title'], '每日巡检（改）');
    expect(args['prompt'], '跑一遍构建');
    expect(args['cronExpr'], '30 09 * * *', reason: 'daily 档兼容 cron');
    expect(args['scheduleRule'], {
      'unit': 'daily',
      'interval': 1,
      'hour': 9,
      'minute': 30,
    });
    expect(args['scheduleEditedByUser'], true,
        reason: '用户显式改调度须置位（官方语义）');
    expect(args.containsKey('modelSelection'), isFalse,
        reason: '未改选型整体省略（保留原值）');
 // 保存成功 pop 回列表并刷新。
    expect(find.text('编辑定时任务'), findsNothing);
    expect(channel.listCalls, 2, reason: '首载 + 保存后刷新');
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义 cron 档：scheduleRule 显式置 null（清旧规则否则改 cron 不生效）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel();
    await tester.pumpWidget(_host(_EditApp(channel)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.byKey(const ValueKey('automation-card-tap-a1')).first,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
 // 切自定义 cron 档 → 填新表达式 → 保存。
    await tester.tap(find.byKey(const ValueKey('automation-sched-custom')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
      find.byKey(const ValueKey('automation-edit-cron')),
      '*/15 * * * *',
    );
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final args = channel.updateArgs!;
    expect(args['cronExpr'], '*/15 * * * *');
    expect(args['scheduleRule'], isNull,
        reason: '自定义档必须显式清 scheduleRule——旧规则仍是调度权威时改 cron 无效');
    expect(args['scheduleEditedByUser'], true);
  });

  testWidgets('⋮ 菜单含「编辑」入口（官方双入口对位）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel();
    await tester.pumpWidget(_host(_EditApp(channel)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('automation-menu-a1')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('编辑'), findsOneWidget);
    await tester.tap(find.text('编辑').last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('编辑定时任务'), findsOneWidget, reason: '菜单编辑同达编辑页');
  });
}
