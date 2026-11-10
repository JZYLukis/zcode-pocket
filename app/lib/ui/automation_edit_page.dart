import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/automation_client.dart';
import 'app_widgets.dart';

/// 定时任务编辑页（2026-11-05 反馈⑤：此前只可查看——官方
/// updateAutomation（zcodeAgentPluginParams.ts:216-228）完整支持编辑，
/// 桌面整卡点击进编辑，手机端纯没接）。
///
/// 可编辑：标题 / 提示词 / 调度（档位预设或自定义 cron）。调度改动
/// 同时下发 scheduleRule+cronExpr（scheduleRule 是调度权威，cronExpr
/// 恒必填的兼容展示）+ scheduleEditedByUser=true（官方语义：防任务内
/// 自改调度覆盖用户意图）。模型/模式/次数上限维持现状（展示不编辑）。
class AutomationEditPage extends StatefulWidget {
  const AutomationEditPage({super.key, required this.entry});

  final AutomationEntry entry;

  @override
  State<AutomationEditPage> createState() => _AutomationEditPageState();
}

enum _SchedKind { everyMinutes, everyHours, daily, weekly, monthly, custom }

/// 周几中文词表（0=周日，官方 weekdays 同标）——预览与选择器共用。
const weekZh = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

class _AutomationEditPageState extends State<AutomationEditPage> {
  late final TextEditingController _title;
  late final TextEditingController _prompt;
  late final TextEditingController _cron;

  _SchedKind _kind = _SchedKind.custom;
  int _interval = 5;
  int _minute = 0;
  int _hour = 9;
  final Set<int> _weekdays = {};
  int _monthDay = 1;

  /// 1.0.1 真机验收⑦：模式与模型可编辑（官方 updateAutomation 原生
  /// 支持，桌面可改——此前手机端留白）。null=未改不下发。
  String? _mode;
  String? _selProvider;
  String? _selModel;
  String? _selThought;
  bool _modelCleared = false;

  /// 模型目录（modelSelectionView 拉取）：(providerId, 短标签, modelId,
  /// 思考档列表)。
  List<({String pid, String label, String model, List<String> levels})>?
  _catalog;
  bool _catalogLoading = false;

  /// 数字输入控制器缓存（每帧新建会重置光标）。
  final Map<String, TextEditingController> _numControllers = {};

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _title = TextEditingController(text: e.title);
    _prompt = TextEditingController(text: e.prompt);
    _cron = TextEditingController(text: e.cronExpr);
    _prefillSchedule(e);
    _selProvider = e.provider.isEmpty ? null : e.provider;
    _selModel = e.model.isEmpty ? null : e.model;
    _selThought = e.thoughtLevel.isEmpty ? null : e.thoughtLevel;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCatalog());
  }

  Future<void> _loadCatalog() async {
    final app = AppStateScope.of(context);
    if (app.bridge == null) return;
    setState(() => _catalogLoading = true);
    try {
      final view = await app.modelSelectionView();
      final providers = view?['providers'];
      final out = <({String pid, String label, String model, List<String> levels})>[];
      if (providers is List) {
        for (final p in providers) {
          if (p is! Map) continue;
          final pid = '${p['providerId'] ?? ''}';
          if (pid.isEmpty) continue;
          final label = _providerLabel(pid, '${p['providerName'] ?? ''}');
          final models = p['models'];
          if (models is! List) continue;
          for (final m in models) {
            if (m is! Map) continue;
            final mid = '${m['modelId'] ?? ''}';
            if (mid.isEmpty) continue;
            final config = m['config'];
            final specs = config is Map ? config['optionSpecs'] : null;
            final rl = specs is Map ? specs['reasoningLevel'] : null;
            final vals = rl is Map ? rl['values'] : null;
            out.add((
              pid: pid,
              label: label,
              model: mid,
              levels: vals is List
                  ? [for (final v in vals) if (v is String) v]
                  : const <String>[],
            ));
          }
        }
      }
      if (mounted) setState(() => _catalog = out);
    } on Object {
      // 目录不可用：模型行保持只读现状（其余可编辑不受影响）。
    } finally {
      if (mounted) setState(() => _catalogLoading = false);
    }
  }

  /// 短标签（与模型弹页 providerShortLabel 同口径的本地简版）。
  String _providerLabel(String pid, String name) {
    final low = pid.toLowerCase();
    String? family;
    if (low.contains('bigmodel')) family = 'BigModel';
    if (family == null && low.contains('zai')) family = 'Z.AI';
    if (family == null && low.contains('start-plan')) family = 'Start Plan';
    if (family == null && low.contains('opencode-go')) family = 'OCG';
    if (family == null && low.contains('openrouter')) family = 'OpenRouter';
    if (family != null) return low.contains('-api') ? '$family API' : family;
    if (name.isNotEmpty) return name.split(RegExp(r'\s+')).first;
    return pid;
  }

  /// 从既有 scheduleRule（调度权威）预填；缺席则保持「自定义」档展示
  /// 原 cronExpr（避免反向解析猜错）。
  void _prefillSchedule(AutomationEntry e) {
    final rule = e.scheduleRule;
    if (rule == null) return;
    final unit = '${rule['unit'] ?? ''}';
    _interval = (rule['interval'] as num?)?.toInt() ?? 1;
    _minute = (rule['minute'] as num?)?.toInt() ?? 0;
    _hour = (rule['hour'] as num?)?.toInt() ?? 0;
    final days = rule['weekdays'];
    if (days is List) {
      _weekdays.addAll(days.whereType<num>().map((d) => d.toInt()));
    }
    final monthDays = rule['monthDays'];
    if (monthDays is List && monthDays.isNotEmpty) {
      _monthDay = (monthDays.first as num?)?.toInt() ?? 1;
    }
    _kind = switch (unit) {
      'minute' => _SchedKind.everyMinutes,
      'hourly' => _SchedKind.everyHours,
      'daily' => _SchedKind.daily,
      'weekly' => _SchedKind.weekly,
      'monthly' => _SchedKind.monthly,
      _ => _SchedKind.custom,
    };
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    _cron.dispose();
    for (final c in _numControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _numControllerOf(String key, int initial) =>
      _numControllers.putIfAbsent(
        key,
        () => TextEditingController(text: '$initial'),
      );

  /// 档位 → scheduleRule（官方词表：minute|hourly|daily|weekly|monthly）。
  /// 官方 automationCronValidation.ts:52-56 对**任意** unit 都无条件要求
  /// hour/minute 为 0-23 / 0-59 整数——minute/hourly 档此前漏带被服务端
  /// 必拒（保存看似成功、规则未落库）。
  Map<String, dynamic>? _buildScheduleRule() {
    switch (_kind) {
      case _SchedKind.everyMinutes:
        // unit=minute 不使用对齐时分，但仍须携带合法整数（官方校验）；
        // 预填值原样透传（既有 minute 规则的时分不丢）。
        return {
          'unit': 'minute',
          'interval': _interval,
          'hour': _hour,
          'minute': _minute,
        };
      case _SchedKind.everyHours:
        return {
          'unit': 'hourly',
          'interval': _interval,
          'hour': _hour,
          'minute': _minute,
        };
      case _SchedKind.daily:
        return {
          'unit': 'daily',
          'interval': 1,
          'hour': _hour,
          'minute': _minute,
        };
      case _SchedKind.weekly:
        if (_weekdays.isEmpty) return null;
        return {
          'unit': 'weekly',
          'interval': 1,
          'hour': _hour,
          'minute': _minute,
          'weekdays': _weekdays.toList()..sort(),
        };
      case _SchedKind.monthly:
        final rule = widget.entry.scheduleRule;
        // monthlyMode=weekday（如「每月第二个周三」）在本表单没有周几
        // 编辑器——用户只改时分时按原结构透传，绝不用有损投影改写成
        // date 模式（写 date 等于把规则语义换掉）。
        final weekdayMode = '${rule?['monthlyMode'] ?? ''}' == 'weekday';
        final monthDayTouched = _monthDay != _ruleMonthDayOf(rule);
        if (weekdayMode && !monthDayTouched) {
          final weekdays = [
            for (final d in (rule?['weekdays'] as List? ?? const []))
              if (d is num) d.toInt(),
          ];
          if (weekdays.isNotEmpty) {
            return {
              'unit': 'monthly',
              'interval': (rule?['interval'] as num?)?.toInt() ?? 1,
              'monthlyMode': 'weekday',
              'weekdays': weekdays,
              'hour': _hour,
              'minute': _minute,
            };
          }
        }
        return {
          'unit': 'monthly',
          // F4（复审）：表单没有「每 N 个月」输入——必须保留原 interval，
          // 恒写 1 会把「每 3 个月」静默降级成「每月」（频次×N）。
          'interval': (rule?['interval'] as num?)?.toInt() ?? 1,
          'monthlyMode': 'date',
          'monthDays': [_monthDay],
          'hour': _hour,
          'minute': _minute,
        };
      case _SchedKind.custom:
        return null;
    }
  }

  /// 既有规则里的「几号」（monthDays[0]，缺省 1）——改号判据与
  /// weekday 模式透传共用。
  int _ruleMonthDayOf(Map<String, dynamic>? rule) {
    final days = rule?['monthDays'];
    if (days is List && days.isNotEmpty) {
      return (days.first as num?)?.toInt() ?? 1;
    }
    return 1;
  }

  /// 档位 → 人话预览（与 AutomationEntry.scheduleLabel 词表同口径；
  /// 动态拼接中文——同 scheduleLabel 现状，i18n 覆盖留后续）。
  String _schedulePreview() {
    String two(int v) => v.toString().padLeft(2, '0');
    const weekZh = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    final hhmm = '${two(_hour)}:${two(_minute)}';
    switch (_kind) {
      case _SchedKind.everyMinutes:
        return _interval == 1 ? '每分钟' : '每 $_interval 分钟';
      case _SchedKind.everyHours:
        return _interval == 1
            ? '每小时（第 ${two(_minute)} 分）'
            : '每 $_interval 小时（第 ${two(_minute)} 分）';
      case _SchedKind.daily:
        return '每天 $hhmm';
      case _SchedKind.weekly:
        if (_weekdays.isEmpty) return '每周（未选择运行日）';
        final days = (_weekdays.toList()..sort())
            .map((d) => weekZh[d.clamp(0, 6)])
            .join('、');
        return '每周 $days $hhmm';
      case _SchedKind.monthly:
        return '每月 $_monthDay 日 $hhmm';
      case _SchedKind.custom:
        final raw = _cron.text.trim();
        return raw.isEmpty ? '自定义 cron（待填写）' : '按 cron 表达式 $raw';
    }
  }

  /// 档位 → 兼容 cronExpr（合法 5 段；调度权威是 scheduleRule）。
  String? _buildCron() {
    String two(int v) => v.toString().padLeft(2, '0');
    switch (_kind) {
      case _SchedKind.everyMinutes:
        final n = _interval <= 0 ? 1 : _interval;
        return n == 1 ? '* * * * *' : '*/$n * * * *';
      case _SchedKind.everyHours:
        final n = _interval <= 0 ? 1 : _interval;
        return n == 1
            ? '${two(_minute)} * * * *'
            : '${two(_minute)} */$n * * *';
      case _SchedKind.daily:
        return '${two(_minute)} ${two(_hour)} * * *';
      case _SchedKind.weekly:
        if (_weekdays.isEmpty) return null;
        // 官方 weekdays 0-6、0=周日；cron DOW 同标（0=Sunday）。
        final dow = _weekdays.toList()..sort();
        return '${two(_minute)} ${two(_hour)} * * ${dow.join(',')}';
      case _SchedKind.monthly:
        final d = _monthDay.clamp(1, 31);
        return '${two(_minute)} ${two(_hour)} $d * *';
      case _SchedKind.custom:
        final raw = _cron.text.trim();
        return raw.isEmpty ? null : raw;
    }
  }

  Future<void> _save() async {
    final cron = _buildCron();
    if (_title.text.trim().isEmpty) {
      _snack('标题不能为空');
      return;
    }
    if (_prompt.text.trim().isEmpty) {
      _snack('提示词不能为空');
      return;
    }
    if (cron == null) {
      _snack(_kind == _SchedKind.weekly
          ? '请选择每周的运行日'
          : '请填写合法的 cron 表达式（5 段）');
      return;
    }
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    if (bridge == null) {
      _snack('未连接电脑');
      return;
    }
    final e = widget.entry;
    final client = AutomationClient(bridge: bridge, scope: {
      'workspacePath': e.workspacePath,
      if (e.workspaceIdentity.isNotEmpty)
        'workspaceIdentity': e.workspaceIdentity,
    });
    setState(() => _saving = true);
    try {
      final modelChanged =
          (_selProvider ?? '') != e.provider ||
          (_selModel ?? '') != e.model ||
          (_selThought ?? '') != e.thoughtLevel;
      // 对抗审查高③：此前无条件重写 scheduleRule——表单是对 rule 的
      // 有损投影（interval>1→1、monthlyMode=weekday→date、yearly→清），
      // 只改标题也会静默改调度。修：只在用户实际改过调度（档位/参数/
      // cron 与预填态不同）才下发调度字段。
      final scheduleChanged = _scheduleChanged(e);
      final updated = await client.update(
        automationId: e.automationId,
        title: _title.text.trim(),
        prompt: _prompt.text.trim(),
        cronExpr: scheduleChanged ? cron : null,
        scheduleRule: scheduleChanged ? _buildScheduleRule() : null,
        clearScheduleRule: scheduleChanged && _kind == _SchedKind.custom,
        scheduleEditedByUser: scheduleChanged ? true : null,
        // 模式/模型只在用户改过才下发（未动不下发=保留原值）。
        mode: _mode,
        provider: modelChanged ? _selProvider : null,
        model: modelChanged ? _selModel : null,
        thoughtLevel: modelChanged ? _selThought : null,
        clearModelSelection: _modelCleared,
      );
      if (!mounted) return;
      if (updated == null) {
        _snack('保存失败：任务不存在或没有可更新的字段');
        return;
      }
      Navigator.of(context).pop(true);
    } catch (err) {
      debugPrint('[automation] 更新失败: $err');
      if (mounted) _snack('保存失败：$err');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 对抗审查高③：判断用户是否实际改过调度（预填态与当前态对比）。
  /// 未改→不下发调度字段（保留原 rule 不被有损投影覆写）。
  bool _scheduleChanged(AutomationEntry e) {
    final rule = e.scheduleRule;
    if (rule == null) {
      // 原 rule 缺失（旧任务）→ 有 cron 输入就算改过。
      return _cron.text.trim() != e.cronExpr;
    }
    // 档位变了。
    final prefillKind = _prefillKindOf(rule);
    if (_kind != prefillKind) return true;
    // 同档位比参数。
    switch (_kind) {
      case _SchedKind.everyMinutes:
        return _interval != ((rule['interval'] as num?)?.toInt() ?? 1);
      case _SchedKind.everyHours:
        return _interval != ((rule['interval'] as num?)?.toInt() ?? 1) ||
            _minute != ((rule['minute'] as num?)?.toInt() ?? 0);
      case _SchedKind.weekly:
        // B4：周几也是调度参数——改选周几（不动时分）必须下发。
        final prefillDays = <int>{
          for (final d in (rule['weekdays'] as List? ?? const []))
            if (d is num) d.toInt(),
        };
        return _hour != ((rule['hour'] as num?)?.toInt() ?? 0) ||
            _minute != ((rule['minute'] as num?)?.toInt() ?? 0) ||
            !setEquals(_weekdays, prefillDays);
      case _SchedKind.daily:
        return _hour != ((rule['hour'] as num?)?.toInt() ?? 0) ||
            _minute != ((rule['minute'] as num?)?.toInt() ?? 0);
      case _SchedKind.monthly:
        // 几号也是调度参数——此前漏比 _monthDay，只改几号静默不生效。
        return _hour != ((rule['hour'] as num?)?.toInt() ?? 0) ||
            _minute != ((rule['minute'] as num?)?.toInt() ?? 0) ||
            _monthDay != _ruleMonthDayOf(rule);
      case _SchedKind.custom:
        return _cron.text.trim() != e.cronExpr;
    }
  }

  _SchedKind _prefillKindOf(Map<String, dynamic> rule) {
    return switch ('${rule['unit'] ?? ''}') {
      'minute' => _SchedKind.everyMinutes,
      'hourly' => _SchedKind.everyHours,
      'daily' => _SchedKind.daily,
      'weekly' => _SchedKind.weekly,
      'monthly' => _SchedKind.monthly,
      _ => _SchedKind.custom,
    };
  }

  /// 当前模式显示值：用户改过用 _mode，否则用任务原值（'' → default）。
  String _modeOf(AutomationEntry e) {
    if (_mode != null) return _mode!;
    final m = e.mode;
    if (m.isEmpty) return 'default';
    // 已知枚举外的原值（如 edit/guarded）映射到最近档位显示。
    return switch (m) {
      'edit' || 'guarded' => 'autonomous',
      'ask' || 'full' => 'yolo',
      'default' || 'build' || 'plan' || 'autonomous' || 'yolo' => m,
      _ => 'default',
    };
  }

  /// 模型选择弹层（目录分组简化版：组头短标签+模型行）。
  void _pickModel() {
    final catalog = _catalog;
    if (catalog == null) return;
    // 按短标签分组保序。
    final groups =
        <String, List<({String pid, String label, String model, List<String> levels})>>{};
    for (final c in catalog) {
      groups.putIfAbsent(c.label, () => []).add(c);
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.65,
          ),
          child: ListView(
            key: const ValueKey('automation-model-picker'),
            // VR-7b（视觉审查 1109）：弹层此前吃满 0.65×屏高约束，短目录
            // （5 行）底部空 202dp。shrinkWrap=true 让内容自收（maxHeight
            // 上限保留=长目录照常滚，physics 不变）。
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            children: [
              for (final g in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                  child: Text(
                    g.key,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ),
                for (final item in g.value)
                  ListTile(
                    key: ValueKey('automation-model-${item.pid}/${item.model}'),
                    dense: true,
                    title: Text(
                      item.model,
                      translate: false,
                      style: const TextStyle(fontSize: AppType.uiBase),
                    ),
                    trailing:
                        _selProvider == item.pid && _selModel == item.model
                        ? Icon(
                            Icons.check,
                            size: 18,
                            color: context.colors.brandAccent,
                          )
                        : null,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      setState(() {
                        _modelCleared = false;
                        _selProvider = item.pid;
                        _selModel = item.model;
                        // 新模型的思考档不在其清单内则清空。
                        if (_selThought != null &&
                            item.levels.isNotEmpty &&
                            !item.levels.contains(_selThought)) {
                          _selThought = null;
                        }
                      });
                    },
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('编辑定时任务'),
        actions: [
          TextButton(
            key: const ValueKey('automation-edit-save'),
            onPressed: _saving ? null : _save,
            child: Text(
              '保存',
              style: TextStyle(
                fontSize: AppType.uiBase,
                color: context.colors.brandAccent,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          const AppSectionHeader('标题'),
          TextField(
            key: const ValueKey('automation-edit-title'),
            controller: _title,
            maxLength: 60,
            decoration: _deco('任务标题'),
          ),
          const SizedBox(height: 8),
          const AppSectionHeader('提示词'),
          TextField(
            key: const ValueKey('automation-edit-prompt'),
            controller: _prompt,
            maxLines: 5,
            minLines: 3,
            decoration: _deco('到点执行的任务指令'),
          ),
          const SizedBox(height: 8),
          const AppSectionHeader('调度'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (kind, label) in [
                (_SchedKind.everyMinutes, '每 N 分钟'),
                (_SchedKind.everyHours, '每 N 小时'),
                (_SchedKind.daily, '每天'),
                (_SchedKind.weekly, '每周'),
                (_SchedKind.monthly, '每月'),
                (_SchedKind.custom, '自定义 cron'),
              ])
                ChoiceChip(
                  key: ValueKey('automation-sched-${kind.name}'),
                  label: Text(label),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                  showCheckmark: true,
                  checkmarkColor: context.colors.brandAccent,
                  // 2026-11-05 审美门建议①：M3 出厂淡紫（浅色）与全局
                  // 品牌语言脱节——选中收口品牌蓝淡底+蓝字+蓝描边，
                  // 未选中=卡底+常规边（深浅两主题一致的中性语言）。
                  backgroundColor: context.colors.card,
                  // B2（2026-11-07 用户批）：浅色选中底=蓝 10%
                  //（#E7EDFF，与全局 secondaryContainer 梯度一致）。
                  selectedColor: context.colors.brandAccent.withValues(
                    alpha: 0.10,
                  ),
                  labelStyle: TextStyle(
                    fontSize: AppType.uiCaption,
                    // B2：深色 brandAccent(#4099FF) 在选中底上 4.09:1
                    // 不达 4.5——深色分支提亮到 #7FB4FF（≈5.8:1）。
                    color: _kind == kind
                        ? context.colors.brandAccentBright
                        : context.colors.foreground,
                    fontWeight: _kind == kind
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                  side: BorderSide(
                    color: _kind == kind
                        ? context.colors.brandAccent.withValues(alpha: 0.45)
                        : context.colors.border,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _scheduleFields(context),
          const SizedBox(height: 8),
          // 2026-11-05 审美门建议②：调度人话预览——改档位即时看到
          // 「将按：每天 09:30」确认句，防改 cron/时刻的误操作。
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 14,
                color: context.colors.foregroundSubtlest,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${tr('将按')}：${_schedulePreview()}',
                  translate: false,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 1.0.1 真机验收⑦：模式/模型从只读升可编辑（官方对齐）。
          const AppSectionHeader('模式'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in [
                  ('default', '默认'),
                  ('build', '变更前确认'),
                  ('plan', '计划模式'),
                  ('autonomous', '自主模式'),
                  ('yolo', '完全访问'),
                ])
                  ChoiceChip(
                    key: ValueKey('automation-mode-$value'),
                    label: Text(label),
                    selected: _modeOf(e) == value,
                    onSelected: (_) => setState(() => _mode = value),
                    showCheckmark: true,
                    checkmarkColor: context.colors.brandAccent,
                    backgroundColor: context.colors.card,
                    // B2：同上——蓝 10% 选中底。
                    selectedColor: context.colors.brandAccent.withValues(
                      alpha: 0.10,
                    ),
                    labelStyle: TextStyle(
                      fontSize: AppType.uiCaption,
                      // B2：深色同款提亮（见上）。
                      color: _modeOf(e) == value
                          ? context.colors.brandAccentBright
                          : context.colors.foreground,
                      fontWeight: _modeOf(e) == value
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                    side: BorderSide(
                      color: _modeOf(e) == value
                          ? context.colors.brandAccent.withValues(alpha: 0.45)
                          : context.colors.border,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const AppSectionHeader('模型'),
          InkWell(
            key: const ValueKey('automation-edit-model'),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: _catalog == null ? null : _pickModel,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _catalogLoading
                          ? '正在获取模型目录…'
                          : _modelCleared || _selModel == null
                          ? '继承默认'
                          : '$_selModel'
                                '${_selThought != null && _selThought!.isNotEmpty ? ' · 思考 $_selThought' : ''}'
                                '${_selProvider != null ? ' · ${_providerLabel(_selProvider!, '')}' : ''}',
                      // VR-7c（视觉审查 1109）：模型值（模型名+思考档+
                      // 来源三层拼接）此前无 maxLines，长名换行把行高顶破
                      // 并与右侧「继承默认」按钮挤压。单行省略。
                      key: const ValueKey('automation-edit-model-value'),
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: _catalog == null
                            ? context.colors.foregroundSubtle
                            : context.colors.foreground,
                      ),
                    ),
                  ),
                  if (_catalog != null) ...[
                    if (!_modelCleared && _selModel != null)
                      TextButton(
                        key: const ValueKey('automation-edit-model-clear'),
                        onPressed: () => setState(() {
                          _modelCleared = true;
                          _selProvider = null;
                          _selModel = null;
                          _selThought = null;
                        }),
                        child: const Text('继承默认'),
                      ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const AppSectionHeader('工作区（不可改）'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              e.workspacePath.isEmpty ? '—' : e.workspacePath,
              translate: false,
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _deco(String hint) => InputDecoration(
    hintText: hint,
    isDense: true,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: BorderSide(color: context.colors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: BorderSide(color: context.colors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: BorderSide(color: context.colors.brandAccent),
    ),
  );

  Widget _numberField(
    String key,
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged,
  ) => SizedBox(
    width: 110,
    child: TextField(
      key: ValueKey(key),
      controller: _numControllerOf(key, value),
      keyboardType: TextInputType.number,
      decoration: _deco(label).copyWith(counterText: ''),
      onChanged: (v) {
        final n = int.tryParse(v.trim());
        if (n != null) onChanged(n.clamp(min, max));
      },
    ),
  );

  Widget _scheduleFields(BuildContext context) {
    switch (_kind) {
      case _SchedKind.everyMinutes:
        return Row(
          children: [
            _numberField(
              'automation-sched-interval',
              '间隔分钟',
              _interval,
              1,
              200,
              (v) => _interval = v,
            ),
          ],
        );
      case _SchedKind.everyHours:
        return Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _numberField(
              'automation-sched-interval',
              '间隔小时',
              _interval,
              1,
              200,
              (v) => _interval = v,
            ),
            _numberField(
              'automation-sched-minute',
              '第几分钟',
              _minute,
              0,
              59,
              (v) => _minute = v,
            ),
          ],
        );
      case _SchedKind.daily:
      case _SchedKind.weekly:
      case _SchedKind.monthly:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // B4（2026-11-07 用户批）：周几选择器——此前 weekly 档只回填
            // 旧值无 UI 可改（对抗审查「周几选择器」遗留实际未修完）。
            // 七只紧凑 chip 与档位/模式 chip 同规格（B2 蓝 10% 选中）。
            // VR-7a（视觉审查 1109）：Wrap 在 375dp 宽下折成 5+2 两行——
            // 改 Row+7×Expanded 等分单行（间距 3dp、内容居中）。
            // 紧凑回滚（候选 13 真机反馈⑤「太松散」）：保单行等分
            //（修掉 5+2 折行），密度回 compact 与档位/模式 chip 同规格。
            if (_kind == _SchedKind.weekly)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    for (var d = 0; d < 7; d++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1.5),
                          child: ChoiceChip(
                            key: ValueKey('automation-sched-weekday-$d'),
                            label: Text(
                              weekZh[d],
                              textAlign: TextAlign.center,
                            ),
                            selected: _weekdays.contains(d),
                            onSelected: (_) => setState(() {
                              _weekdays.contains(d)
                                  ? _weekdays.remove(d)
                                  : _weekdays.add(d);
                            }),
                            showCheckmark: false,
                            // 单行等分后每格 ≈44dp 宽：收紧内边距防溢出。
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            labelPadding:
                                const EdgeInsets.symmetric(horizontal: 2),
                            backgroundColor: context.colors.card,
                            selectedColor: context.colors.brandAccent
                                .withValues(alpha: 0.10),
                            labelStyle: TextStyle(
                              fontSize: AppType.uiXs,
                              color: _weekdays.contains(d)
                                  ? context.colors.brandAccentBright
                                  : context.colors.foregroundSubtle,
                              fontWeight: _weekdays.contains(d)
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            side: BorderSide(
                              color: _weekdays.contains(d)
                                  ? context.colors.brandAccent.withValues(
                                      alpha: 0.45,
                                    )
                                  : context.colors.border,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (_kind == _SchedKind.monthly)
                  _numberField(
                    'automation-sched-monthday',
                    '几号',
                    _monthDay,
                    1,
                    31,
                    (v) => _monthDay = v,
                  ),
                _numberField(
                  'automation-sched-hour',
                  '小时',
                  _hour,
                  0,
                  23,
                  (v) => _hour = v,
                ),
                _numberField(
                  'automation-sched-minute',
                  '分钟',
                  _minute,
                  0,
                  59,
                  (v) => _minute = v,
                ),
              ],
            ),
          ],
        );
      case _SchedKind.custom:
        return TextField(
          key: const ValueKey('automation-edit-cron'),
          controller: _cron,
          decoration: _deco('分 时 日 月 周（如 */5 * * * *）'),
        );
    }
  }
}
