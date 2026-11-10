import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/automation_client.dart';
import 'app_widgets.dart';
import 'automation_edit_page.dart';

// 优化批 #3：异常→人话映射（原始异常仍在调用方 debugPrint 留痕）。
String friendlyError(Object e) {
  final msg = '$e';
  if (msg.contains('TimeoutException') || msg.contains('timeout')) {
    return '网络不佳，请稍后再试';
  }
  if (msg.contains('401') || msg.contains('auth')) {
    return '账号凭据失效，请重新登录';
  }
  return '加载失败，请重试';
}

/// 定时任务列表页（阶段 3 第三段：列表 + 启停/立即运行/重启/删除；
/// 2026-11-05 反馈⑤补编辑闭环——整卡点击/菜单进编辑页，官方
/// updateAutomation 通道；创建仍属桌面端）。
///
/// 交互对照官方 AutomationsSection.tsx：状态筛选（全部/进行中/已完成/
/// 失败）、失败徽标优先于生命周期徽标、调度摘要 scheduleRule 优先 cron
/// 兜底、"下次运行"仅 active 且无失败时展示、删除破坏性确认。
class AutomationPage extends StatefulWidget {
  const AutomationPage({super.key});

  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

enum _AutomationFilter { all, inProgress, completed, failed }

class _AutomationPageState extends State<AutomationPage> {
  List<AutomationEntry>? _entries;
  String? _error;
  bool _busy = false;
  _AutomationFilter _filter = _AutomationFilter.all;

  AutomationClient? _client() {
    final bridge = AppStateScope.of(context).bridge;
    final ws = AppStateScope.of(context).activeWorkspace;
    if (bridge == null || ws == null) return null;
    return AutomationClient(bridge: bridge, scope: ws);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final client = _client();
    if (client == null) {
      setState(() => _error = '未连接工作区');
      return;
    }
    setState(() => _busy = true);
    try {
      final entries = await client.list();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // 优化批 #3：原始异常只进日志，用户可见文案走人话映射。
      debugPrint('[automation] 列表加载失败: $e');
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 写操作按官方路由到自动化归属的工作区（automationManagementStore
  /// .ts:118-129 resolveAutomationActionScope）。
  AutomationClient? _actionClient(AutomationEntry e) {
    final bridge = AppStateScope.of(context).bridge;
    if (bridge == null) return null;
    return AutomationClient(bridge: bridge, scope: {
      'workspacePath': e.workspacePath,
      if (e.workspaceIdentity.isNotEmpty) 'workspaceIdentity': e.workspaceIdentity,
    });
  }

  Future<void> _runActions(Future<dynamic> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$e')));
      }
      return;
    }
    await _load();
  }

  Future<void> _runNow(AutomationEntry e) async {
    final client = _actionClient(e);
    if (client == null) return;
    // 本页唯一未包错误处理的写操作
    // ——runNow 是 15s 超时的通道 RPC，断网/超时异常逃逸成未处理异步
    // 错误且零反馈。对齐 _runActions 包裹范式，成功路径保留按 status
    // 分档提示。
    final String status;
    try {
      status = await client.runNow(e.automationId);
    } catch (err) {
      debugPrint('[automation] 立即运行失败: $err');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：${friendlyError(err)}')));
      }
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          switch (status) {
            'queued' => '正在运行「${e.title.isEmpty ? '未命名任务' : e.title}」',
            'duplicate' => '该任务已在运行',
            _ => '已触发（$status）',
          },
        ),
      ),
    );
    await _load();
  }

  /// 2026-11-05 反馈⑤：编辑（官方 AutomationsSection.tsx:1700 整卡点击
  /// + 菜单编辑双入口对位）；保存成功后刷新列表。
  Future<void> _edit(AutomationEntry e) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AutomationEditPage(entry: e)),
    );
    if (changed == true) await _load();
  }

  Future<void> _toggleEnabled(AutomationEntry e) async {
    final client = _actionClient(e);
    if (client == null) return;
    await _runActions(() => client.setEnabled(e.automationId, !e.enabled));
  }

  Future<void> _restart(AutomationEntry e) async {
    final client = _actionClient(e);
    if (client == null) return;
    await _runActions(() => client.restart(e.automationId));
  }

  Future<void> _delete(AutomationEntry e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除定时任务'),
        content: Text(
          '确定删除「${e.title.isEmpty ? '未命名任务' : e.title}」？此操作无法撤销。',
          translate: e.title.isEmpty,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.destructive,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = _actionClient(e);
    if (client == null) return;
    await _runActions(() => client.delete(e.automationId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('定时任务'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('刷新'),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final entries = _entries;
    if (_error != null && entries == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(fontSize: AppType.uiCaption)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (entries == null) {
      // 优化批 #2：裸转圈换带说明的 AppLoading。
      return const Center(child: AppLoading('正在加载自动化…'));
    }
    return Column(
      children: [
        _filterRow(entries),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _filteredList(entries).isEmpty
                ? ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    children: [
                      SizedBox(height: 120),
                      Icon(
                        Icons.schedule_outlined,
                        size: 40,
                        color: context.colors.foregroundSubtlest,
                      ),
                      SizedBox(height: 12),
                      Center(
                        child: Text(
                          '没有定时任务\n在电脑端 ZCode 设置里创建',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    key: const ValueKey('automation-list'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: _filteredList(entries).length,
                    itemBuilder: (_, i) {
                      final e = _filteredList(entries)[i];
                      return _AutomationCard(
                        entry: e,
                        onEdit: () => _edit(e),
                        onRunNow: () => _runNow(e),
                        onToggle: () => _toggleEnabled(e),
                        onRestart: () => _restart(e),
                        onDelete: () => _delete(e),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  List<AutomationEntry> _filteredList(List<AutomationEntry> entries) {
    switch (_filter) {
      case _AutomationFilter.all:
        return entries;
      case _AutomationFilter.inProgress:
        // 官方 inProgress=active|paused（进行中含已暂停，未结束）。
        return entries
            .where(
              (e) =>
                  e.lifecycleStatus == 'active' || e.lifecycleStatus == 'paused',
            )
            .toList();
      case _AutomationFilter.completed:
        return entries
            .where((e) => e.lifecycleStatus == 'completed')
            .toList();
      case _AutomationFilter.failed:
        // 官方 failed 组包含"最近一次运行失败"的循环任务（automationStatus
        // Filter.ts:41-46）。
        return entries.where((e) => e.hasFailureState).toList();
    }
  }

  Widget _filterRow(List<AutomationEntry> entries) {
    const labels = {
      _AutomationFilter.all: '全部',
      _AutomationFilter.inProgress: '进行中',
      _AutomationFilter.completed: '已完成',
      _AutomationFilter.failed: '失败',
    };
    int count(_AutomationFilter f) {
      final saved = _filter;
      _filter = f;
      final n = _filteredList(entries).length;
      _filter = saved;
      return n;
    }

    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final f in _AutomationFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      key: ValueKey('automation-filter-${f.name}'),
                      selected: _filter == f,
                      label: Text('${labels[f]} (${count(f)})'),
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AutomationCard extends StatelessWidget {
  final AutomationEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onRunNow;
  final VoidCallback onToggle;
  final VoidCallback onRestart;
  final VoidCallback onDelete;

  const _AutomationCard({
    required this.entry,
    required this.onEdit,
    required this.onRunNow,
    required this.onToggle,
    required this.onRestart,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final completedDim = e.lifecycleStatus == 'completed';
    final (color, label, icon) = _statusBadge(context);
    return Container(
      key: ValueKey('automation-card-${e.automationId}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.border),
      ),
      // 官方：completed 卡整体降透明度。
      foregroundDecoration: completedDim
          ? BoxDecoration(
              color: context.colors.background.withValues(alpha: AppAlpha.strong),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            )
          : null,
      // 2026-11-05 反馈⑤：整卡可点进编辑（官方 AutomationsSection
      // L1700-1710 onClick 同款）；菜单操作不冒泡（PopupMenu 自带手势域）。
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('automation-card-tap-${e.automationId}'),
          onTap: onEdit,
          child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    e.title.isEmpty ? '(未命名任务)' : e.title,
                    translate: e.title.isEmpty,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(fontSize: AppType.uiXs, color: color),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('automation-menu-${e.automationId}'),
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: context.colors.foregroundSubtlest,
                  ),
                  onSelected: (v) {
                    switch (v) {
                      case 'edit':
                        onEdit();
                      case 'run':
                        onRunNow();
                      case 'toggle':
                        onToggle();
                      case 'restart':
                        onRestart();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('编辑'),
                    ),
                    const PopupMenuItem(
                      value: 'run',
                      child: Text('立即运行'),
                    ),
                    // 官方：启停仅 active|paused 展示（AutomationsSection
                    // .tsx:320-322 canToggleAutomation）。
                    if (e.lifecycleStatus == 'active' ||
                        e.lifecycleStatus == 'paused')
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(e.enabled ? '暂停' : '恢复'),
                      ),
                    // 官方：重启仅 failed（其余状态服务端静默 no-op）。
                    if (e.lifecycleStatus == 'failed')
                      const PopupMenuItem(
                        value: 'restart',
                        child: Text('重启'),
                      ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        '删除',
                        style: TextStyle(color: context.colors.destructive),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (e.prompt.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                e.prompt,
                translate: false,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.foregroundSubtlest.withValues(alpha: AppAlpha.faint),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    e.scheduleLabel(),
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _metaLine(),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ),
                ),
              ],
            ),
            if (e.lastError.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '最近错误：${e.lastError}',
                translate: false,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.destructive,
                ),
              ),
            ],
          ],
        ),
      ),
      ),
      ),
    );
  }

  String _metaLine() {
    final parts = <String>[];
    // 官方："下次运行 {相对时间}"仅 active 且无失败时展示。
    if (entry.lifecycleStatus == 'active' &&
        entry.nextRunAt != null &&
        !entry.hasFailureState) {
      parts.add(tr('下次运行 ${_relative(entry.nextRunAt!)}'));
    }
    if (entry.runCount > 0) parts.add(tr('已运行 ${entry.runCount} 次'));
    final ws = entry.workspacePath;
    if (ws.isNotEmpty) {
      final norm = ws.replaceAll('\\', '/');
      parts.add(norm.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => ws));
    }
    return parts.join(' · ');
  }

  (Color, String, IconData) _statusBadge(BuildContext context) {
    final e = entry;
    // 官方：失败态优先于生命周期徽标（hasAutomationFailureState）。
    if (e.hasFailureState) {
      return (context.colors.destructive, '失败', Icons.warning_amber_rounded);
    }
    return switch (e.lifecycleStatus) {
      // 视觉走查①：与筛选词"进行中"统一（官方 inProgress 组=active+paused）。
      'active' => (
        context.colors.running,
        '进行中',
        Icons.schedule,
      ),
      'paused' => (
        context.colors.foregroundSubtlest,
        '已暂停',
        Icons.stop_circle_outlined,
      ),
      'completed' => (
        context.colors.foregroundSubtlest,
        '已完成',
        Icons.check_circle_outline,
      ),
      _ => (
        context.colors.foregroundSubtlest,
        e.lifecycleStatus.isEmpty ? '未知' : e.lifecycleStatus,
        Icons.help_outline,
      ),
    };
  }
}

String _relative(int millis) {
  final diff = millis - DateTime.now().millisecondsSinceEpoch;
  if (diff <= 0) return '即将运行';
  final mins = diff ~/ 60000;
  if (mins < 1) return '1 分钟内';
  if (mins < 60) return '$mins 分钟后';
  final hours = mins ~/ 60;
  if (hours < 24) return '$hours 小时后';
  final days = hours ~/ 24;
  return '$days 天后';
}
