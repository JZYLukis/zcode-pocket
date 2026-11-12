// 定时任务编辑闭环回归（2026-11-05 反馈⑤：此前只可查看——整卡无
// onTap、菜单无编辑、客户端无 updateAutomation）。锁：整卡点击进编辑
// 页 → 改标题/调度档位 → 保存下发 updateAutomation（scheduleRule 为
// 调度权威 + cronExpr 兼容 + scheduleEditedByUser）→ 返回刷新列表；
// 自定义 cron 档显式置 null 清旧规则（否则旧规则仍是权威、改 cron 不
// 生效）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/localized_text.dart' as lt;
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

  /// 可选列表覆写（weekly 等特定档位用例）。
  List<Map<String, dynamic>>? listOverride;

  /// 可选模型目录覆写（5 行短目录弹层收缩用例）。
  Map<String, dynamic>? viewOverride;

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
        if (listOverride != null) return listOverride;
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
      case 'getView':
        if (viewOverride != null) return viewOverride;
        return {
          'providers': [
            {
              'providerId': 'account:zai-individual-coding-plan',
              'models': [
                {
                  'modelId': 'glm-5.3',
                  'config': {
                    'optionSpecs': {
                      'reasoningLevel': {'values': ['low', 'high']},
                    },
                  },
                },
              ],
            },
          ],
        };
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

  /// 编辑页模型目录走 modelSelectionView（AppState._conv 路由）——
  /// 夹具直供目录数据。
  @override
  Future<Map<String, dynamic>?> modelSelectionView() async {
    final res = await channel.call('model-selection', 'getView', []);
    return res is Map ? res.cast<String, dynamic>() : null;
  }

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
    // 高③修复：只改标题（未动调度）→ 调度字段不下发（防
    // 有损投影覆写原 rule）。cron/scheduleRule/scheduleEditedByUser
    // 均缺省。
    expect(args.containsKey('cronExpr'), isFalse,
        reason: '未改调度不下发 cron（高③修复）');
    expect(args.containsKey('scheduleRule'), isFalse,
        reason: '未改调度不下发 scheduleRule（高③修复）');
    expect(args.containsKey('scheduleEditedByUser'), isFalse,
        reason: '未改调度不置 scheduleEditedByUser（高③修复）');
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

  // （2026-11-07 用户批）：weekly 档周几选择器——此前只回填旧值无 UI
  // 可改（「周几选择器」遗留实际未修完）。红=旧代码无 chip 可点。
  testWidgets('每周档：周几选择器可改 → weekdays 随 scheduleRule 下发', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel()
      ..listOverride = [
        {
          'automationId': 'a1',
          'title': '周巡检',
          'prompt': '跑一遍构建',
          'cronExpr': '30 9 * * 1,3',
          'enabled': true,
          'recurring': true,
          'lifecycleStatus': 'active',
          'workspacePath': 'G:/Demo App',
          'workspaceIdentity': 'ws1',
          'scheduleRule': {
            'unit': 'weekly',
            'interval': 1,
            'hour': 9,
            'minute': 30,
            'weekdays': [1, 3],
          },
        },
      ];
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
    // 每周档选中 + 七只周几 chip 在场（旧代码：无选择器=找不到）。
    expect(find.byKey(const ValueKey('automation-sched-weekly')), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-sched-weekday-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-sched-weekday-5')), findsOneWidget);
    // （视觉走查）：Wrap 在 375dp 下折成 5+2 两行——
    // 修=Row+7×Expanded 等分单行。红=第 6/7 只 y 中心下移一行。
    final weekdayCenters = <Offset>[];
    final weekdaySizes = <Size>[];
    for (var d = 0; d < 7; d++) {
      final f = find.byKey(ValueKey('automation-sched-weekday-$d'));
      weekdayCenters.add(tester.getCenter(f));
      weekdaySizes.add(tester.getSize(f));
    }
    final minY = weekdayCenters
        .map((c) => c.dy)
        .reduce((a, b) => a < b ? a : b);
    final maxY = weekdayCenters
        .map((c) => c.dy)
        .reduce((a, b) => a > b ? a : b);
    expect(maxY - minY, lessThan(0.5), reason: '七只周几 chip 单行（y 中心一致）');
    final gaps = <double>[
      for (var i = 1; i < 7; i++) weekdayCenters[i].dx - weekdayCenters[i - 1].dx,
    ];
    final minGap = gaps.reduce((a, b) => a < b ? a : b);
    final maxGap = gaps.reduce((a, b) => a > b ? a : b);
    expect(maxGap - minGap, lessThan(2.0), reason: 'Expanded 等分（相邻 x 间距一致）');
    expect(minGap, greaterThan(20.0), reason: '等分后每格仍有余量，非重叠');
    for (final s in weekdaySizes) {
      // 紧凑回滚（候选 13 反馈⑤）：单行等分保留，密度回 compact
      //（40dp；红=折成 5+2 两行/过疏 48dp）。
      expect(s.height, greaterThanOrEqualTo(36));
      expect(s.height, lessThanOrEqualTo(44));
    }
    // 旧值回填：周一(1)/周三(3)选中态（checkmark 无、蓝底判断走 selected
    // chip 的 label 色——直接改选最稳：补选周五(5)）。
    await tester.tap(find.byKey(const ValueKey('automation-sched-weekday-5')));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final args = channel.updateArgs;
    expect(args, isNotNull, reason: '保存调用 updateAutomation');
    final rule = args!['scheduleRule'] as Map;
    expect(rule['unit'], 'weekly');
    expect(rule['weekdays'], [1, 3, 5], reason: '补选周五后 1/3/5 排序下发');
    expect(rule['hour'], 9);
    expect(rule['minute'], 30);
    expect(args['scheduleEditedByUser'], isTrue);
    expect(tester.takeException(), isNull);
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

  // 1.0.1 真机验收⑦：模式/模型可编辑（官方对齐）。锁：改模式+换模型
  // → update 下发 mode+modelSelection；未动不下发。
  // 1.0.1 真机验收⑦：模式/模型可编辑（官方对齐）。锁：改模式+换模型
  // → update 下发 mode+modelSelection；未动不下发。
  testWidgets('模式+模型可编辑：改档下发 mode/modelSelection，未动不下发', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel();
    await tester.pumpWidget(_host(_EditApp(channel)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.byKey(const ValueKey('automation-card-tap-a1')).first,
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 目录已拉（模型行可点）。
    expect(
      find.byKey(const ValueKey('automation-edit-model')),
      findsOneWidget,
    );
    // 改模式→plan。
    await tester.tap(find.byKey(const ValueKey('automation-mode-plan')));
    await tester.pump(const Duration(milliseconds: 100));
    // 换模型→glm-5.3（zai 个人组）。
    await tester.tap(find.byKey(const ValueKey('automation-edit-model')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.byKey(const ValueKey(
        'automation-model-account:zai-individual-coding-plan/glm-5.3',
      )),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final args = channel.updateArgs!;
    expect(args['mode'], 'plan', reason: '模式改过才下发');
    expect(args['modelSelection'], {
      'providerId': 'account:zai-individual-coding-plan',
      'modelId': 'glm-5.3',
    }, reason: '模型换过下发完整选型');
  });

  // （视觉走查）：模型弹层 ListView 吃满 0.65×屏高约束——
  // 5 行短目录底部空 202dp。修=shrinkWrap:true（maxHeight 上限保留）。
  // 红=修复前弹层高 0.65×806≈524dp（真机 880 高≈572dp）。
  testWidgets('模型弹层按内容收缩（5 行目录 < 半屏）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final channel = _EditChannel()
      ..viewOverride = {
        'providers': [
          {
            'providerId': 'account:zai-individual-coding-plan',
            'models': [
              for (var i = 0; i < 5; i++)
                {
                  'modelId': 'glm-short-$i',
                  'config': {
                    'optionSpecs': {
                      'reasoningLevel': {'values': ['low', 'high']},
                    },
                  },
                },
            ],
          },
        ],
      };
    await tester.pumpWidget(_host(_EditApp(channel)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.byKey(const ValueKey('automation-card-tap-a1')).first,
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('automation-edit-model')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final picker = find.byKey(const ValueKey('automation-model-picker'));
    expect(picker, findsOneWidget);
    // 5 行目录全部渲染（短目录不收成滚动视口）。
    for (var i = 0; i < 5; i++) {
      expect(
        find.byKey(ValueKey(
          'automation-model-account:zai-individual-coding-plan/glm-short-$i',
        )),
        findsOneWidget,
      );
    }
    final h = tester.getSize(picker).height;
    expect(h, lessThan(806 * 0.5),
        reason: '5 行目录弹层高 < 半屏（修复前 0.65×806≈524dp）');
    expect(h, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  // （视觉走查）：模型值行（模型名+思考档+来源三层拼接）
  // 无 maxLines——长名换行顶破行高并挤压右侧按钮。修=单行省略。
  testWidgets('模型值 Text 单行省略（maxLines=1）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final channel = _EditChannel();
    await tester.pumpWidget(_host(_EditApp(channel)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.byKey(const ValueKey('automation-card-tap-a1')).first,
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final value = tester.widget<lt.Text>(
      find.byKey(const ValueKey('automation-edit-model-value')),
    );
    expect(value.maxLines, 1, reason: '模型值单行（修复前无 maxLines）');
    expect(value.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  // 高②：官方 automationCronValidation.ts:52-56 对任意 unit 都
  // 要求 hour/minute 整数——minute/hourly 档漏带必被服务端拒（红=旧
  // _buildScheduleRule 只回 unit/interval）。
  testWidgets('每 N 分钟档：scheduleRule 补 hour/minute（否则服务端必拒）', (
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
    await tester.tap(find.byKey(const ValueKey('automation-sched-everyMinutes')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
      find.byKey(const ValueKey('automation-sched-interval')),
      '15',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final rule = channel.updateArgs!['scheduleRule'] as Map;
    expect(rule['unit'], 'minute');
    expect(rule['interval'], 15);
    expect(rule['hour'], isA<int>(),
        reason: '官方校验要求任意 unit 携带 0-23 整数 hour');
    expect(rule['minute'], isA<int>(),
        reason: '官方校验要求任意 unit 携带 0-59 整数 minute');
  });

  testWidgets('每 N 小时档：scheduleRule 补 hour（此前只带 minute）', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('automation-sched-everyHours')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final rule = channel.updateArgs!['scheduleRule'] as Map;
    expect(rule['unit'], 'hourly');
    expect(rule['hour'], 9, reason: '预填每天 09:30 的小时值透传');
    expect(rule['minute'], 30);
  });

  // 红=旧 _scheduleChanged 的 daily/monthly 共分支只比时分，只改几号
  // 静默不下发（保存成功但调度没变）。
  testWidgets('每月档：只改几号也触发 scheduleChanged 并下发 monthDays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel()
      ..listOverride = [
        {
          'automationId': 'a1',
          'title': '月巡检',
          'prompt': '跑一遍构建',
          'cronExpr': '30 9 15 * *',
          'enabled': true,
          'recurring': true,
          'lifecycleStatus': 'active',
          'workspacePath': 'G:/Demo App',
          'workspaceIdentity': 'ws1',
          'scheduleRule': {
            'unit': 'monthly',
            'interval': 1,
            'monthlyMode': 'date',
            'monthDays': [15],
            'hour': 9,
            'minute': 30,
          },
        },
      ];
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
    await tester.enterText(
      find.byKey(const ValueKey('automation-sched-monthday')),
      '20',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final rule = channel.updateArgs!['scheduleRule'] as Map;
    expect(rule['monthlyMode'], 'date');
    expect(rule['monthDays'], [20], reason: '只改几号必须下发（红=旧实现静默不生效）');
  });

  // （复审）：monthly date 档表单没有「每 N 个月」输入——保存必须
  // 保留原 interval（修复前恒写 1，把「每 3 个月」静默降级成每月）。
  testWidgets('F4：每月档保留原 interval（每 3 个月不降级成每月）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel()
      ..listOverride = [
        {
          'automationId': 'a2',
          'title': '季巡检',
          'prompt': '季度报表',
          'cronExpr': '30 9 1 */3 *',
          'enabled': true,
          'recurring': true,
          'lifecycleStatus': 'active',
          'workspacePath': 'G:/Demo App',
          'workspaceIdentity': 'ws1',
          'scheduleRule': {
            'unit': 'monthly',
            'interval': 3,
            'monthlyMode': 'date',
            'monthDays': [1],
            'hour': 9,
            'minute': 30,
          },
        },
      ];
    await tester.pumpWidget(_host(_EditApp(channel)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.byKey(const ValueKey('automation-card-tap-a2')).first,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 只改时分（不动日期）→ scheduleChanged 触发但 interval 必须保 3。
    await tester.enterText(
      find.byKey(const ValueKey('automation-sched-hour')),
      '10',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final rule = channel.updateArgs!['scheduleRule'] as Map;
    expect(rule['interval'], 3, reason: '修复前恒写 1（频次×3 语义丢失）');
    expect(rule['monthDays'], [1]);
    expect(rule['hour'], 10);
  });

  // 官方 monthlyMode=weekday（如每月第几个周三）：表单没有周几编辑器，
  // 只改时分时必须原结构透传——旧实现恒写成 date 模式=规则语义被换掉。
  testWidgets('每月 weekday 模式：只改时分保真 weekdays/monthlyMode', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final channel = _EditChannel()
      ..listOverride = [
        {
          'automationId': 'a1',
          'title': '第二个周三巡检',
          'prompt': '跑一遍构建',
          'cronExpr': '30 9 * * 3',
          'enabled': true,
          'recurring': true,
          'lifecycleStatus': 'active',
          'workspacePath': 'G:/Demo App',
          'workspaceIdentity': 'ws1',
          'scheduleRule': {
            'unit': 'monthly',
            'interval': 2,
            'monthlyMode': 'weekday',
            'weekdays': [3],
            'hour': 9,
            'minute': 30,
          },
        },
      ];
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
    // 只改小时（几号字段未动=1）。
    await tester.enterText(
      find.byKey(const ValueKey('automation-sched-hour')),
      '10',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('automation-edit-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final rule = channel.updateArgs!['scheduleRule'] as Map;
    expect(rule['monthlyMode'], 'weekday', reason: '不得被有损投影改写成 date');
    expect(rule['weekdays'], [3], reason: 'weekdays 原结构透传');
    expect(rule['interval'], 2, reason: '既有 interval 保真');
    expect(rule['hour'], 10);
    expect(rule.keys.contains('monthDays'), isFalse,
        reason: 'weekday 模式不伪造 monthDays');
  });
}
