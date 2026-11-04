import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart';
import 'task_home.dart';

/// 归档任务浏览页（阶段 3 第三段，对照官方归档区交互）：
/// 列表 + 单条恢复/删除 + 全部删除（destructive 确认；批量走官方
/// deleteArchivedTasks，结果三分计数提示）。
class ArchivedTasksPage extends StatefulWidget {
  const ArchivedTasksPage({super.key});

  @override
  State<ArchivedTasksPage> createState() => _ArchivedTasksPageState();
}

class _ArchivedTasksPageState extends State<ArchivedTasksPage> {
  bool _busy = false;

  Future<void> _run(Future<dynamic> Function() action, String okText) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await action();
      messenger.showSnackBar(SnackBar(content: Text(okText)));
      if (mounted) {
        if (res is Map &&
            res['skippedTaskIds'] is List &&
            (res['skippedTaskIds'] as List).isNotEmpty) {
          messenger.showSnackBar(
            const SnackBar(content: Text('部分任务已不在归档态，跳过')),
          );
        }
        setState(() {}); // app.archivedTasks 经 reload 已更新
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(Map<String, dynamic> task) async {
    final app = AppStateScope.of(context);
    await _run(
      () => app.unarchiveTask('${task['taskId']}'),
      '已恢复「${_titleOf(task)}」',
    );
  }

  Future<void> _deleteOne(Map<String, dynamic> task) async {
    // app 在 await 前取（确认框 await 后用 context 触发跨 async gap lint）。
    final app = AppStateScope.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: '删除这个归档任务？',
      message: '任务将从任务列表和归档列表中移除（官方同款语义，不可恢复）。',
    );
    if (!confirmed) return;
    await _run(
      () => app.deleteArchivedTask('${task['taskId']}'),
      '已删除「${_titleOf(task)}」',
    );
  }

  Future<void> _deleteAll(List<Map<String, dynamic>> tasks) async {
    final app = AppStateScope.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: '删除全部归档任务',
      message: '将删除 ${tasks.length} 个归档任务（不可恢复）。确定继续？',
      confirmLabel: '全部删除',
    );
    if (!confirmed) return;
    // 开源审查 L3 P3-8：确认框 await 期间列表可能变化——按现值取删除集
    // 与计数（服务端 skippedTaskIds 仍兜底“已不在归档态”提示）。
    final current = app.archivedTasks;
    await _run(
      () =>
          app.deleteArchivedTasks([for (final t in current) '${t['taskId']}']),
      '已清理 ${current.length} 个归档任务',
    );
  }

  static String _titleOf(Map<String, dynamic> task) {
    final t = '${task['title'] ?? ''}'.trim();
    return t.isEmpty ? '未命名任务' : t;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('已归档任务'),
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('刷新'),
            // 开源审查 L3 P3-7：任务索引模型未建（工作区从未打开）时
            // reloadTaskIndex 静默早退——给可见反馈而非零动作。
            onPressed: _busy
                ? null
                : () {
                    if (app.taskList == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('先连接工作区后才能刷新归档列表')),
                      );
                      return;
                    }
                    app.reloadTaskIndex();
                  },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: app.taskList ?? _noopNotifier,
        builder: (context, _) {
          final tasks = app.archivedTasks;
          if (tasks.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.archive_outlined,
                    size: 40,
                    color: context.colors.foregroundSubtlest,
                  ),
                  SizedBox(height: 12),
                  Text(
                    '没有归档任务',
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ],
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '归档的任务不在任务列表显示；可恢复或删除',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtlest,
                        ),
                      ),
                    ),
                    // 视觉审查②：破坏性批量操作用危险色（审查发现：纯文字
                    // 无警示性、易误触）。
                    TextButton.icon(
                      key: const ValueKey('archive-delete-all'),
                      onPressed: _busy ? null : () => _deleteAll(tasks),
                      icon: Icon(
                        Icons.delete_sweep_outlined,
                        size: 16,
                        color: context.colors.destructive,
                      ),
                      label: Text(
                        '全部删除',
                        style: TextStyle(color: context.colors.destructive),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('archived-task-list'),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: tasks.length,
                  itemBuilder: (_, i) {
                    final t = tasks[i];
                    final updatedAt = (t['updatedAt'] as num?)?.toInt() ?? 0;
                    return Container(
                      key: ValueKey('archived-task-${t['taskId']}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: context.colors.card,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: context.colors.border),
                      ),
                      child: ListTile(
                        title: Text(
                          _titleOf(t),
                          translate: false,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: AppType.uiBase),
                        ),
                        subtitle: Text(
                          // 开源审查 P1 P2-2：pattern 占位不递归 tr——
                          // 相对时间片段在拼接前先 tr（'3 天前'→'3 days
                          // ago'），整串再由 custom pattern 译为
                          // 'Archived 3 days ago'。
                          updatedAt > 0
                              ? '归档于 ${tr(_relative(updatedAt))}'
                              : '已归档',
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.foregroundSubtlest,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              key: ValueKey('archive-restore-${t['taskId']}'),
                              onPressed: _busy ? null : () => _restore(t),
                              // 开源审查 L1 P3-1：归档语境的「恢复」是
                              // Restore（官方词）；沿用通用键会译成会话语
                              // 态的 Resume——换独立键按词典事实修正。
                              child: const Text('恢复任务'),
                            ),
                            IconButton(
                              key: ValueKey('archive-delete-${t['taskId']}'),
                              onPressed: _busy ? null : () => _deleteOne(t),
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: context.colors.foregroundSubtle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// 开源审查 L2 P3-11：相对时间收敛到 task_home 单源（原第二份实现不
// 支持注入 now，且与任务中心版本细节漂移）。
String _relative(int millis) => taskHomeRelativeTime(millis);

/// 空任务列表模型时的占位 listenable（app.taskList 可为 null）。
final _noopNotifier = ChangeNotifier();
