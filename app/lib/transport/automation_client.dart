import 'channel_client.dart';
import 'companion_client.dart';

/// A scheduled/automation task on the desktop (`zcode-agent.listAllAutomations`).
///
/// 字段对照官方 ZCodeAutomation（automation-types.ts:65-101 + rowToAutomation
/// automationRepo.ts:114-149）。注意：顶层 model/provider/thoughtLevel 是
/// sqlite 旧列、返回恒缺席——模型信息一律走 modelSelection（2026-10-19
/// 官方语义仲裁，ADR 0023 批）。
class AutomationEntry {
  final String automationId;
  final String title;
  final String prompt;
  final String cronExpr;
  final String mode;
  final bool recurring;
  final Map<String, dynamic>? scheduleRule;
  final bool enabled;
  final String lifecycleStatus;
  final int runCount;
  final int? lastRunAt;
  final int? nextRunAt;
  final int createdAt;
  final int updatedAt;

  /// 官方补全字段（列表页徽标/路由用）。
  final String workspaceKey;
  final String workspacePath;
  final String workspaceIdentity;
  final String targetTaskId; // 非空=会话内创建的 cron（编辑须保留 cronExpr）
  final String locationKind; // "local" | "remote"
  final int? maxRuns;
  final int? endAt;
  final String dispatchStatus; // idle|claimed|dispatched|failed_to_dispatch
  final int dispatchAttempts;
  final int? retryAt;
  final String lastError;
  final bool scheduleEditedByUser;

  /// modelSelection 投影：{providerId, modelId, options.reasoningLevel}。
  final String model;
  final String provider;
  final String thoughtLevel;
  final Map<String, dynamic>? modelSelection;
  final Map<String, dynamic> raw;

  AutomationEntry(this.raw)
    : automationId = '${raw['automationId'] ?? ''}',
      title = '${raw['title'] ?? ''}',
      prompt = '${raw['prompt'] ?? ''}',
      cronExpr = '${raw['cronExpr'] ?? ''}',
      mode = '${raw['mode'] ?? ''}',
      recurring = raw['recurring'] == true,
      // 开源审查 H2-P3-8：畸形行（字段非 Map）此前硬 cast 抛 TypeError
      // 炸整个列表——改 is Map 判定式取值（与其余字段的宽松解析一致）。
      scheduleRule = raw['scheduleRule'] is Map
          ? (raw['scheduleRule'] as Map).cast<String, dynamic>()
          : null,
      enabled = raw['enabled'] == true,
      lifecycleStatus = '${raw['lifecycleStatus'] ?? ''}',
      runCount = (raw['runCount'] as num?)?.toInt() ?? 0,
      lastRunAt = (raw['lastRunAt'] as num?)?.toInt(),
      nextRunAt = (raw['nextRunAt'] as num?)?.toInt(),
      createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt = (raw['updatedAt'] as num?)?.toInt() ?? 0,
      workspaceKey = '${raw['workspaceKey'] ?? ''}',
      workspacePath = '${raw['workspacePath'] ?? ''}',
      workspaceIdentity = '${raw['workspaceIdentity'] ?? ''}',
      targetTaskId = '${raw['targetTaskId'] ?? ''}',
      locationKind = '${raw['locationKind'] ?? 'local'}',
      maxRuns = (raw['maxRuns'] as num?)?.toInt(),
      endAt = (raw['endAt'] as num?)?.toInt(),
      dispatchStatus = '${raw['dispatchStatus'] ?? 'idle'}',
      dispatchAttempts = (raw['dispatchAttempts'] as num?)?.toInt() ?? 0,
      retryAt = (raw['retryAt'] as num?)?.toInt(),
      lastError = '${raw['lastError'] ?? ''}',
      scheduleEditedByUser = raw['scheduleEditedByUser'] == true,
      modelSelection = raw['modelSelection'] is Map
          ? (raw['modelSelection'] as Map).cast<String, dynamic>()
          : null,
      model = _ms(raw, 'modelId'),
      provider = _ms(raw, 'providerId'),
      thoughtLevel = _msOptions(raw, 'reasoningLevel');

  static String _ms(Map raw, String key) {
    final ms = raw['modelSelection'];
    return ms is Map ? '${ms[key] ?? ''}' : '';
  }

  static String _msOptions(Map raw, String key) {
    final ms = raw['modelSelection'];
    if (ms is! Map) return '';
    final opts = ms['options'];
    return opts is Map ? '${opts[key] ?? ''}' : '';
  }

  /// 官方失败判定（automationFormat.ts:25-31 hasAutomationFailureState）：
  /// lifecycle failed ‖ dispatchStatus failed_to_dispatch ‖ lastError 非空。
  bool get hasFailureState =>
      lifecycleStatus == 'failed' ||
      dispatchStatus == 'failed_to_dispatch' ||
      lastError.isNotEmpty;

  /// 重试队列徽标（automationFormat.ts:34-41）。
  bool get hasRetryQueue =>
      dispatchStatus == 'failed_to_dispatch' &&
      dispatchAttempts > 0 &&
      retryAt != null;

  /// Human-readable schedule, e.g. `每 5 分钟` / `每天 11:17` / `每周 周一`.
  /// 优先 scheduleRule（调度权威），缺省解析 cronExpr（automationCardSchedule
  /// 同款：scheduleRule 优先、cron 兜底）。
  String scheduleLabel() {
    // 开源审查 H2-P2-2（官方 automationCardSchedule.ts:30-35 对位）：相对
    // 时间一次性任务（"4 分钟后提醒"）被存成 minute scheduleRule 只是
    // 兼容展示形态，跑一次即结束——recurring=false 且 maxRuns<=1 统一
    // 显示「自定义」，防误读成"每 N 分钟"循环。
    // 仅当载荷**显式**声明非循环且 maxRuns<=1 才是真一次性任务；
    // recurring 字段缺失（旧快照/精简夹具）不推断——否则 weekly/daily
    // 等词表标签会被整体吞成「自定义」。
    if (raw.containsKey('recurring') && !recurring && (maxRuns ?? 1) <= 1) {
      return '自定义';
    }
    final rule = scheduleRule;
    if (rule != null) {
      final label = _scheduleRuleLabel(rule);
      if (label != null) return label;
    }
    return cronExpr.isEmpty ? '—' : cronExpr;
  }

  static String? _scheduleRuleLabel(Map<String, dynamic> rule) {
    final unit = '${rule['unit'] ?? ''}';
    final interval = (rule['interval'] as num?)?.toInt() ?? 1;
    final h = (rule['hour'] as num?)?.toInt() ?? 0;
    final m = (rule['minute'] as num?)?.toInt() ?? 0;
    switch (unit) {
      // 官方词表（zcode-protocol/index.ts:3828-3841 + automationService
      // :89-134）：minute|hourly|daily|weekly|monthly|yearly。
      case 'minute':
        return interval == 1 ? '每分钟' : '每 $interval 分钟';
      case 'hourly':
        return interval == 1
            ? '每小时（${_two(m)} 分）'
            : '每 $interval 小时（${_two(m)} 分）';
      case 'daily':
        return interval == 1
            ? '每天 ${_two(h)}:${_two(m)}'
            : '每 $interval 天 ${_two(h)}:${_two(m)}';
      case 'weekly':
        final days = rule['weekdays'];
        final dayLabel = days is List && days.isNotEmpty
            ? (days
                  .map((d) => _weekdayLabel(d))
                  .where((s) => s.isNotEmpty)
                  .join('、'))
            : '';
        // 开源审查 H1-P3-06：interval==1 特例（daily/hourly/minute 均有，
        // weekly/monthly 此前缺——「每 1 周 周一」观感，官方口径「每周一」）。
        final prefix = interval == 1 ? '每周' : '每 $interval 周';
        return '$prefix${dayLabel.isEmpty ? '' : ' $dayLabel'}';
      case 'monthly':
        final mode = '${rule['monthlyMode'] ?? 'date'}';
        final monthPrefix = interval == 1 ? '每月' : '每 $interval 月';
        if (mode == 'weekday') {
          return '$monthPrefix（按周几）';
        }
        final days = rule['monthDays'];
        final dayLabel = days is List && days.isNotEmpty ? '${days.join('、')}' : '';
        return '$monthPrefix${dayLabel.isEmpty ? '' : ' $dayLabel 日'}';
      case 'yearly':
        final months = rule['months'];
        final monthLabel = months is List && months.isNotEmpty
            ? '${months.join('、')} 月'
            : '';
        return '每年$monthLabel';
      default:
        return null; // 未知词表 → 回落 cronExpr
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _weekdayLabel(Object? dow) {
    // 官方 weekdays 0-6、0=周日（automationCron.ts:170-186）。
    const names = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    if (dow is num && dow >= 0 && dow < 7) return names[dow.toInt()];
    return '';
  }
}

/// Client for the scheduled/automation RPC on the `zcode-agent` channel.
class AutomationClient {
  final BridgeSession bridge;
  final Map<String, dynamic> scope;

  const AutomationClient({required this.bridge, required this.scope});

  ChannelClient get _channels => bridge.channels;

  Map<String, dynamic> get _scopeMap => {
    'workspacePath': scope['workspacePath'],
    if (scope['workspaceIdentity'] != null)
      'workspaceIdentity': scope['workspaceIdentity'],
  };

  /// All automations (active + completed)——官方不按 workspace 过滤，返回
  /// 全部项目（zcodeAgentService.ts:4975-4977；automationManagementStore
  /// .ts:143"定时任务管理视图展示所有项目的任务"）。
  Future<List<AutomationEntry>> list() async {
    final res = await _channels.call('zcode-agent', 'listAllAutomations', [
      _scopeMap,
    ], timeout: const Duration(seconds: 30));
    if (res is! List) return const [];
    return [
      for (final item in res.whereType<Map>())
        AutomationEntry(item.cast<String, dynamic>()),
    ];
  }

  /// Creates an automation（官方 zcodeAgentPluginParams.ts:187-198）。
  ///
  /// [scheduleRule] 官方词表：unit=minute|hourly|daily|weekly|monthly|yearly
  /// （weekly 必须带 weekdays[0-6，0=周日]、monthly 按 monthlyMode 带
  /// monthDays 或 weekdays，zcode-protocol/index.ts:3828-3841 +
  /// automationService.ts:89-134）；anchorAt 服务端创建时会用 Date.now()
  /// 覆盖，调用方不必精确计算。cronExpr 恒必填（合法 5 段 cron）；有
  /// scheduleRule 时它是调度权威、cronExpr 仅兼容展示。总数上限 20。
  /// modelSelection 官方 strict 键：providerId/modelId/options.reasoningLevel。
  Future<AutomationEntry> create({
    required String title,
    required String prompt,
    required String cronExpr,
    required String model,
    required String provider,
    required String mode,
    required String thoughtLevel,
    required bool recurring,
    required Map<String, dynamic> scheduleRule,
    int? maxRuns,
    int? endAt,
  }) async {
    final res = await _channels.call('zcode-agent', 'createAutomation', [
      {
        ..._scopeMap,
        'title': title,
        'prompt': prompt,
        'cronExpr': cronExpr,
        if (mode.isNotEmpty) 'mode': mode,
        'recurring': recurring,
        'scheduleRule': scheduleRule,
        if (maxRuns != null) 'maxRuns': maxRuns,
        if (endAt != null) 'endAt': endAt,
        // modelSelection 官方 strict（model-selection.ts:4-17）：providerId/
        // modelId 均 min1——空串会被 zod 拒（toSmall）；无选型整体省略
        // （可选项）。旧 provider/model/thoughtLevel 拼写会被剥离（M4 审计
        // + 2026-10-19 仲裁修正）。
        if (provider.isNotEmpty && model.isNotEmpty)
          'modelSelection': {
            'providerId': provider,
            'modelId': model,
            if (thoughtLevel.isNotEmpty)
              'options': {'reasoningLevel': thoughtLevel},
          },
      },
    ], timeout: const Duration(seconds: 20));
    return AutomationEntry(
      res is Map ? res.cast<String, dynamic>() : <String, dynamic>{},
    );
  }

  /// Runs an automation now. Returns `{status: 'queued' | 'duplicate'}`
  /// （zcodeAgent.ts:199-201；对 completed 状态仍可手动跑，不改变生命周期）。
  Future<String> runNow(String automationId) async {
    final res = await _channels.call('zcode-agent', 'runAutomationNow', [
      {..._scopeMap, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
    return res is Map ? '${res['status'] ?? ''}' : '';
  }

  /// Enables or disables an automation.
  Future<dynamic> setEnabled(String automationId, bool enabled) {
    return _channels.call('zcode-agent', 'setAutomationEnabled', [
      {..._scopeMap, 'automationId': automationId, 'enabled': enabled},
    ], timeout: const Duration(seconds: 15));
  }

  /// Deletes an automation（硬删除不可恢复——automationRepo.ts:549-559，
  /// UI 侧必须破坏性确认）。
  Future<dynamic> delete(String automationId) {
    return _channels.call('zcode-agent', 'deleteAutomation', [
      {..._scopeMap, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
  }

  /// Restarts a failed automation（仅 lifecycleStatus==='failed' 有效，
  /// 其他状态服务端静默 no-op——automationService.ts:440-450）。
  Future<dynamic> restart(String automationId) {
    return _channels.call('zcode-agent', 'restartAutomation', [
      {..._scopeMap, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
  }
}
