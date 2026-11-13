import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/automation_client.dart';
import 'package:zcode_pocket/ui/composer_panels.dart';
import 'package:zcode_pocket/ui/quota_banner.dart';
import 'package:zcode_pocket/transport/conversation.dart';

class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data[key] = value ?? '';
  }
}

void main() {
  group('F18 跨工作区搜索过滤（filterCrossWorkspaceTasks）', () {
    final tasks = [
      {
        'taskId': 't1',
        'title': '修复登录页崩溃',
        'workspacePath': 'G:\\A',
        'workspaceLabel': 'A',
      },
      {
        'taskId': 't2',
        'title': '登录性能优化',
        'workspaceIdentity': 'ws-b',
        'workspacePath': 'G:\\B',
        'workspaceLabel': 'B',
      },
      {
        'taskId': 't3',
        'title': '登录页样式',
        'workspacePath': 'G:\\A',
        'archived': true,
      },
      {
        'taskId': '',
        'title': '登录',
        'workspacePath': 'G:\\C',
      },
      {
        'taskId': 't5',
        'title': '无关任务',
        'workspacePath': 'G:\\C',
      },
    ];

    test('命中非活跃工作区、剔归档、剔空 id、剔活跃列表重复', () {
      final res = filterCrossWorkspaceTasks(
        workspaceTasks: tasks,
        activeKey: 'G:\\A',
        activeIds: const {},
        query: '登录',
      );
      expect(res.map((t) => t['taskId']).toList(), ['t2']);
    });

    test('活跃列表已含的 id 不重复出现（即使标题命中）', () {
      final res = filterCrossWorkspaceTasks(
        workspaceTasks: tasks,
        activeKey: 'G:\\A',
        activeIds: const {'t2'},
        query: '登录',
      );
      expect(res, isEmpty);
    });

    test('空查询恒空（关闭搜索即无跨区结果）', () {
      final res = filterCrossWorkspaceTasks(
        workspaceTasks: tasks,
        activeKey: 'G:\\A',
        activeIds: const {},
        query: '  ',
      );
      expect(res, isEmpty);
    });

    test('大小写不敏感命中', () {
      final res = filterCrossWorkspaceTasks(
        workspaceTasks: [
          {'taskId': 'x', 'title': 'Fix LOGIN page', 'workspacePath': 'G:\\B'},
        ],
        activeKey: 'G:\\A',
        activeIds: const {},
        query: 'login',
      );
      expect(res.length, 1);
    });

    test('workspaceIdentity 优先作 key 匹配', () {
      final res = filterCrossWorkspaceTasks(
        workspaceTasks: tasks,
        activeKey: 'ws-b',
        activeIds: const {},
        query: '登录',
      );
      // t2 属于 ws-b=活跃区被剔；只剩其他工作区的（t1/t3 在 G:\A——
      // t1 命中、t3 归档、空 id 剔）→ 命中 t1。
      expect(res.map((t) => t['taskId']).toList(), ['t1']);
    });
  });

  group('AutomationEntry 解析（官方字段对照，2026-10-19 终验探针实证）', () {
    test('终验探针实测形态：scheduleRule/anchorAt/dispatchStatus', () {
      final e = AutomationEntry({
        'automationId': 'automation-x',
        'title': '[probe] t',
        'cronExpr': '15 09 * * *',
        'prompt': 'p',
        'workspaceKey': 'G:\\Demo App',
        'workspacePath': 'G:\\Demo App',
        'locationKind': 'local',
        'recurring': true,
        'scheduleRule': {
          'unit': 'daily',
          'interval': 1,
          'hour': 9,
          'minute': 15,
          'anchorAt': 1792000000000,
        },
        'runCount': 0,
        'enabled': true,
        'lifecycleStatus': 'active',
        'nextRunAt': 1792006372000,
        'dispatchStatus': 'idle',
        'dispatchAttempts': 0,
        'createdAt': 1792000000001,
        'updatedAt': 1792000000002,
      });
      expect(e.hasFailureState, isFalse);
      expect(e.hasRetryQueue, isFalse);
      expect(e.scheduleLabel(), '每天 09:15');
      expect(e.workspacePath, 'G:\\Demo App');
      expect(e.dispatchStatus, 'idle');
    });

    test('modelSelection 嵌套投影（providerId/modelId/options.reasoningLevel）', () {
      final e = AutomationEntry({
        'automationId': 'a',
        'title': 't',
        'cronExpr': '* * * * *',
        'prompt': 'p',
        'modelSelection': {
          'providerId': 'account:bigmodel',
          'modelId': 'glm-5.3',
          'options': {'reasoningLevel': 'high'},
        },
        'enabled': true,
        'lifecycleStatus': 'active',
      });
      expect(e.provider, 'account:bigmodel');
      expect(e.model, 'glm-5.3');
      expect(e.thoughtLevel, 'high');
      // 顶层旧列恒缺席——投影不误读。
      expect(e.raw.containsKey('model'), isFalse);
    });

    test('失败判定：lifecycle failed ‖ dispatch failed_to_dispatch ‖ lastError', () {
      expect(
        AutomationEntry({
          'automationId': 'a',
          'lifecycleStatus': 'failed',
        }).hasFailureState,
        isTrue,
      );
      expect(
        AutomationEntry({
          'automationId': 'a',
          'lifecycleStatus': 'active',
          'dispatchStatus': 'failed_to_dispatch',
        }).hasFailureState,
        isTrue,
      );
      expect(
        AutomationEntry({
          'automationId': 'a',
          'lifecycleStatus': 'active',
          'lastError': 'boom',
        }).hasFailureState,
        isTrue,
      );
      expect(
        AutomationEntry({
          'automationId': 'a',
          'lifecycleStatus': 'active',
          'lastError': '',
        }).hasFailureState,
        isFalse,
      );
    });

    test('scheduleRule 词表标签（weekly/monthly 官方词表）', () {
      String label(Map rule) => AutomationEntry({
        'automationId': 'a',
        'scheduleRule': rule,
      }).scheduleLabel();
      expect(
        label({'unit': 'minute', 'interval': 5}),
        '每 5 分钟',
      );
      expect(
        label({'unit': 'hourly', 'interval': 1, 'minute': 30}),
        '每小时（30 分）',
      );
      expect(
        label({
          'unit': 'weekly',
          'interval': 1,
          'weekdays': [1, 3],
        }),
        contains('周一、周三'),
      );
      expect(
        label({'unit': 'monthly', 'interval': 1, 'monthDays': [1, 15]}),
        contains('1、15'),
      );
      // 未知词表回落 cronExpr。
      expect(
        label({'unit': 'bogus', 'interval': 1}).isEmpty ||
            label({'unit': 'bogus', 'interval': 1}) == '—',
        isTrue,
      );
    });
  });

  group('配额横幅状态机（官方 sessionQuotaBannerState 对齐； 修复批总门）', () {
    const sp = 'account:bigmodel-start-plan';
    Map<String, dynamic> snap({
      List<Map<String, dynamic>>? limits,
      int? now,
      String providerId = sp,
    }) => {
      'serverTime': now ?? 1000,
      'provider': {'id': providerId},
      'quota': {'limits': limits},
    };

    test('无 quota/limits → 无横幅', () {
      expect(
        buildQuotaBannerState({}, activeProviderId: sp, modelId: 'glm-4.7'),
        isNull,
      );
      expect(
        buildQuotaBannerState({'quota': null},
            activeProviderId: sp, modelId: 'glm-4.7'),
        isNull,
      );
      expect(
        buildQuotaBannerState({'quota': {'limits': []}},
            activeProviderId: sp, modelId: 'glm-4.7'),
        isNull,
      );
    });

    test('Coding Pro 快照不出桶式横幅（官方 provider 总门）', () {
      // 用户实见路径：TOKENS_LIMIT 新周期 0 已用时 percentage=0，
      // 旧逻辑误报"剩余 0%"；官方 isStartPlanModelProviderId 早退整路拦。
      const codingPro = 'account:bigmodel-individual-coding-plan';
      final st = buildQuotaBannerState(
        snap(limits: [
          {'meter': '', 'type': 'TOKENS_LIMIT', 'percentage': 0, 'number': 5},
          {'meter': '', 'type': 'TIME_LIMIT', 'percentage': 55,
              'remaining': 442, 'number': 1000},
        ], providerId: codingPro),
        activeProviderId: codingPro,
        modelId: 'glm-4.7',
      );
      expect(st, isNull);
    });

    test('快照 provider 与活跃 provider 不一致 → 无横幅', () {
      final st = buildQuotaBannerState(
        snap(limits: [
          {'meter': 'model_usage', 'remaining': 50, 'number': 1000,
              'bucketId': 'b1', 'periodStart': 0, 'periodEnd': 2000,
              'usageDetails': [
                {'modelCode': 'glm-4.7', 'usage': 1},
              ]},
        ]),
        activeProviderId: 'account:zai-start-plan',
        modelId: 'glm-4.7',
      );
      expect(st, isNull);
    });

    test('全桶耗尽 → 不可关闭的耗尽横幅', () {
      final st = buildQuotaBannerState(
        snap(limits: [
          {'meter': 'model_usage', 'remaining': 0, 'number': 1000,
              'periodStart': 0, 'periodEnd': 2000},
          {'meter': 'model_usage', 'remaining': -5, 'number': 100,
              'periodStart': 0, 'periodEnd': 2000},
        ]),
        activeProviderId: sp,
        modelId: 'glm-4.7',
      );
      expect(st, isNotNull);
      expect(st!.exhausted, isTrue);
    });

    test('单桶剩余≤10% → 低额度提醒（可关）', () {
      final st = buildQuotaBannerState(
        snap(limits: [
          {'meter': 'model_usage', 'remaining': 50, 'number': 1000,
              'bucketId': 'b1', 'periodStart': 0, 'periodEnd': 2000,
              'usageDetails': [
                {'modelCode': 'glm-4.7', 'usage': 1},
              ]},
        ]),
        activeProviderId: sp,
        modelId: 'glm-4.7',
      );
      expect(st, isNotNull);
      expect(st!.exhausted, isFalse);
      expect(st.ratio, closeTo(0.05, 0.001));
      expect(st.reminderKey, 'b1/0/2000');
      expect(st.referenceTime, 1000);
      expect(st.reminderExpiresAt, 2000);
    });

    test('低额提醒模型过滤（官方 bucketMatchesModel）', () {
      final limits = [
        {'meter': 'model_usage', 'remaining': 50, 'number': 1000,
            'bucketId': 'b1', 'periodStart': 0, 'periodEnd': 2000,
            'usageDetails': [
              {'modelCode': 'glm-4.6', 'usage': 1},
            ]},
      ];
      // 模型不匹配 → 无低额提醒。
      expect(
        buildQuotaBannerState(snap(limits: limits),
            activeProviderId: sp, modelId: 'glm-4.7'),
        isNull,
      );
      // 模型缺省 → 官方语义同样不出低额（仅耗尽横幅不受影响）。
      expect(
        buildQuotaBannerState(snap(limits: limits), activeProviderId: sp),
        isNull,
      );
      // 归一化命中：前缀 model: + 下划线→连字符（官方 normalizeQuotaModel）。
      expect(
        buildQuotaBannerState(
          snap(limits: [
            {'meter': 'model_usage', 'remaining': 50, 'number': 1000,
                'bucketId': 'b1', 'periodStart': 0, 'periodEnd': 2000,
                'usageDetails': [
                  {'modelCode': 'model:GLM_4_7', 'usage': 1},
                ]},
          ]),
          activeProviderId: sp,
          modelId: '早前批次',
        ),
        isNotNull,
      );
    });

    test('ratio=0 跳过 + 无效 reminderKey 不弹（官方 0<比例≤10% 与 !key 门）', () {
      // remaining=0 的单桶：官方 ratio<=0 → continue，且另一桶有余不判耗尽。
      expect(
        buildQuotaBannerState(
          snap(limits: [
            {'meter': 'model_usage', 'remaining': 0, 'number': 1000,
                'bucketId': 'b1', 'periodStart': 0, 'periodEnd': 2000,
                'usageDetails': [
                  {'modelCode': 'glm-4.7', 'usage': 1},
                ]},
            {'meter': 'model_usage', 'remaining': 800, 'number': 1000,
                'periodStart': 0, 'periodEnd': 2000},
          ]),
          activeProviderId: sp,
          modelId: 'glm-4.7',
        ),
        isNull,
      );
      // 无 bucketId（TOKENS_LIMIT 类载荷）：官方 bucketReminderKey=null 不提醒。
      expect(
        buildQuotaBannerState(
          snap(limits: [
            {'meter': 'model_usage', 'percentage': 0.08,
                'periodStart': 0, 'periodEnd': 2000,
                'usageDetails': [
                  {'modelCode': 'glm-4.7', 'usage': 1},
                ]},
          ]),
          activeProviderId: sp,
          modelId: 'glm-4.7',
        ),
        isNull,
      );
    });

    test('时间窗外/非 model_usage 桶不参与', () {
      final st = buildQuotaBannerState(
        snap(limits: [
          {'meter': 'model_usage', 'remaining': 0, 'number': 100,
              'periodEnd': 500}, // 已过期
          {'meter': 'other', 'remaining': 0, 'number': 100,
              'periodStart': 0, 'periodEnd': 2000},
        ]),
        activeProviderId: sp,
        modelId: 'glm-4.7',
      );
      expect(st, isNull);
    });

    test('未知 remaining 不当 0（官方 allBucketsExhausted 语义）', () {
      final st = buildQuotaBannerState(
        snap(limits: [
          {'meter': 'model_usage', 'number': 100,
              'periodStart': 0, 'periodEnd': 2000}, // remaining 缺席
        ]),
        activeProviderId: sp,
        modelId: 'glm-4.7',
      );
      expect(st, isNull); // 不判耗尽也不触发低额（比例未知）
    });

    test('percentage 兜底比例（Start Plan 0-1 剩余口径）', () {
      final st = buildQuotaBannerState(
        snap(limits: [
          {'meter': 'model_usage', 'percentage': 0.08,
              'bucketId': 'b1', 'periodStart': 0, 'periodEnd': 2000,
              'usageDetails': [
                {'modelCode': 'glm-4.7', 'usage': 1},
              ]},
        ]),
        activeProviderId: sp,
        modelId: 'glm-4.7',
      );
      expect(st, isNotNull);
      expect(st!.ratio, closeTo(0.08, 0.001));
    });
  });

  group('低额提醒持久化（UiPrefs，官方 reminderStore 语义）', () {
    test('展示即记录+快照时间判到期+往返保持', () async {
      final storage = _FakeSecureStorage();
      final prefs = UiPrefs(storage: storage);
      await prefs.load();
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 1000), isFalse);
      await prefs.markQuotaReminderShown('b1/0/2000', 2000, 1000);
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 1000), isTrue);
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 1999), isTrue);
      // 到期后（快照时间越过 expiresAt）不再隐藏。
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 2000), isFalse);
      // 重启往返：新实例从存储恢复记录。
      final prefs2 = UiPrefs(storage: storage);
      await prefs2.load();
      expect(prefs2.isQuotaReminderHidden('b1/0/2000', 1500), isTrue);
      // 非法参数不落（官方 markShown 守卫）。
      await prefs2.markQuotaReminderShown('', 2000, 1000);
      await prefs2.markQuotaReminderShown('b2/0/1', 1000, 1000); // expires<=ref
      expect(prefs2.isQuotaReminderHidden('', 1000), isFalse);
      expect(prefs2.isQuotaReminderHidden('b2/0/1', 500), isFalse);
    });

    test('周期滚动：陈旧条目不挡新周期记录（K2 P1）', () async {
      final storage = _FakeSecureStorage();
      final prefs = UiPrefs(storage: storage);
      await prefs.load();
      // 周期 1 展示 → 落 {K: 2000}。
      await prefs.markQuotaReminderShown('b1/0/2000', 2000, 1000);
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 1500), isTrue);
      // 周期滚动（快照时间越过旧 expiresAt）：新周期横幅应再出现。
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 2500), isFalse);
      // 新周期展示 → 落新 expiresAt（修复前：陈旧条目挡住，新值永不落，
      // 跨页面实例/重启横幅每周期反复弹）。
      await prefs.markQuotaReminderShown('b1/0/2000', 4000, 2500);
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 2500), isTrue,
          reason: '新周期记录必须覆盖陈旧条目');
      expect(prefs.isQuotaReminderHidden('b1/0/2000', 3999), isTrue);
      // 重启往返：新周期记录持久化。
      final prefs2 = UiPrefs(storage: storage);
      await prefs2.load();
      expect(prefs2.isQuotaReminderHidden('b1/0/2000', 3000), isTrue);
    });

  });

  group('斜杠面板混入子代理候选（filterSlashCommands）', () {
    final cmds = <SlashCommand>[
      SlashCommand.fromMap({'name': 'compact', 'description': '压缩上下文'}),
      SlashCommand.fromMap({'name': 'init', 'description': '初始化'}),
    ];
    final agents = [
      {'name': 'reviewer', 'description': '代码审查'},
      {'name': 'tester', 'description': '测试'},
    ];

    test('命令与子代理混合、kind 区分', () {
      final res = filterSlashCommands(cmds, '', subagents: agents);
      expect(
        res.where((c) => c['kind'] == 'command').length,
        2,
      );
      expect(
        res.where((c) => c['kind'] == 'subagent').length,
        2,
      );
    });

    test('查询过滤两者', () {
      final res = filterSlashCommands(cmds, 're', subagents: agents);
      expect(res.length, 1);
      expect(res.first['kind'], 'subagent');
      expect(res.first['name'], 'reviewer');
    });
  });

  group('全文搜索命中处理（listTaskList 结果拆分/合并/片段）', () {
    final hits = [
      {
        'taskId': 'a1',
        'title': '当前工作区正文命中',
        'workspaceIdentity': 'ws-a',
        'workspacePath': 'G:\\A',
        'searchSnippet': '…里提到过 payment gateway 的配置…',
      },
      {
        'taskId': 'p1',
        'title': '当前工作区置顶命中',
        'workspaceIdentity': 'ws-a',
        'workspacePath': 'G:\\A',
      },
      {
        'taskId': 'b1',
        'title': '其他工作区命中',
        'workspaceIdentity': 'ws-b',
        'workspacePath': 'G:\\B',
        'searchSnippets': ['', '正文片段二'],
      },
      {'taskId': '', 'title': '坏行', 'workspacePath': 'G:\\B'},
      {
        'taskId': 'b1',
        'title': '同任务重复行',
        'workspaceIdentity': 'ws-b',
        'workspacePath': 'G:\\B',
      },
    ];

    test('拆分：当前工作区归 id 集，其他工作区去重归行集', () {
      final res = splitSearchHitsByWorkspace(
        hits: hits,
        activeKey: 'ws-a',
      );
      expect(res.currentIds, {'a1', 'p1'});
      expect(res.crossHits.map((t) => t['taskId']).toList(), ['b1']);
    });

    test('identity 优先、回退 path 作为归属 key', () {
      final res = splitSearchHitsByWorkspace(
        hits: [
          {'taskId': 'a1', 'workspacePath': 'G:\\A'},
        ],
        activeKey: 'G:\\A',
      );
      expect(res.currentIds, {'a1'});
      expect(res.crossHits, isEmpty);
    });

    test('合并：官方命中在前，本地标题命中补充去重', () {
      final merged = mergeCrossSearchHits(
        serverHits: [
          {'taskId': 'b1', 'title': '官方命中'},
        ],
        localHits: [
          {'taskId': 'b1', 'title': '本地重复'},
          {'taskId': 'c1', 'title': '本地补充'},
          {'taskId': '', 'title': '本地坏行'},
        ],
      );
      expect(merged.map((t) => t['taskId']).toList(), ['b1', 'c1']);
    });

    test('片段读取：snippets 数组跳过空串，回退单段字段', () {
      expect(
        firstSearchSnippet({
          'searchSnippets': ['', '  ', '片段A'],
          'searchSnippet': '片段B',
        }),
        '片段A',
      );
      expect(firstSearchSnippet({'searchSnippet': '片段B'}), '片段B');
      expect(firstSearchSnippet({'searchSnippets': ['']}), isNull);
    });
  });
}
