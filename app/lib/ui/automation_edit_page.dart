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
  Map<String, dynamic>? _buildScheduleRule() {
    switch (_kind) {
      case _SchedKind.everyMinutes:
        return {'unit': 'minute', 'interval': _interval};
      case _SchedKind.everyHours:
        return {'unit': 'hourly', 'interval': _interval, 'minute': _minute};
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
        return {
          'unit': 'monthly',
          'interval': 1,
          'monthlyMode': 'date',
          'monthDays': [_monthDay],
          'hour': _hour,
          'minute': _minute,
        };
      case _SchedKind.custom:
        return null;
    }
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
      final updated = await client.update(
        automationId: e.automationId,
        title: _title.text.trim(),
        prompt: _prompt.text.trim(),
        cronExpr: cron,
        scheduleRule: _buildScheduleRule(),
        clearScheduleRule: _kind == _SchedKind.custom,
        scheduleEditedByUser: true,
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
                  selectedColor: context.colors.brandAccent.withValues(
                    alpha: 0.12,
                  ),
                  labelStyle: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: _kind == kind
                        ? context.colors.brandAccent
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
          const AppSectionHeader('维持现状（不可改）'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '模型 ${e.model.isEmpty ? '继承默认' : e.model}'
              '${e.thoughtLevel.isNotEmpty ? ' · 思考 ${e.thoughtLevel}' : ''}'
              '\n模式 ${e.mode.isEmpty ? '默认' : e.mode}'
              '\n工作区 ${e.workspacePath.isEmpty ? '—' : e.workspacePath}',
              translate: false,
              style: TextStyle(
                fontSize: AppType.uiCaption,
 // 审美门建议③：只读区承载模型/模式/工作区等关键上下文，
 // 升到正文前景色档（原 subtle 偏淡）。
                color: context.colors.foreground,
                height: 1.6,
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
        return Wrap(
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
