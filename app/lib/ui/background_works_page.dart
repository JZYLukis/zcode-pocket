// 后台工作二级页（早前批次，候选 13 真机反馈②）：
// 用户拍板「后台工作占空间过大——是否有必要在一级页面看到？收起来
// 放进二级页面」+桌面端收起形态参考（收起=零占位，展开才占空间）。
// 交付：完全撤出输入区一级空间，入口=会话 ⋮ 任务菜单（有后台工作才
// 出现，带计数），页面=列表+运行项取消；一级感知保留任务卡后台小点
//（B 批既有）。数据=传入 ConversationState（与订阅同源，Listenable
// 实时刷新）。行渲染沿用原 BackgroundWorksPanel 语义（kind 三族图标+
// 人话状态词），原面板组件随本批退役。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../transport/conversation.dart';

class BackgroundWorksPage extends StatelessWidget {
  final String sessionId;
  final ConversationState state;
  final Future<void> Function(String sessionId, String workId) onCancel;

  const BackgroundWorksPage({
    super.key,
    required this.sessionId,
    required this.state,
    required this.onCancel,
  });

  static IconData _iconOf(String kind) => switch (kind) {
        'bash' => Icons.terminal_outlined,
        'subagent' => Icons.smart_toy_outlined,
        'workflow' => Icons.account_tree_outlined,
        _ => Icons.work_outline,
      };

  static (Color, String) _statusOf(BuildContext context, String status) =>
      switch (status) {
        'running' => (context.colors.running, '执行中'),
        'resultPending' => (context.colors.foregroundSubtle, '已完成待投递'),
        'failed' => (context.colors.destructive, '失败'),
        'cancelled' => (context.colors.foregroundSubtlest, '已取消'),
        _ => (context.colors.foregroundSubtlest, status),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('后台工作 · ${state.backgroundWorks.length}'),
      ),
      body: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final works = state.backgroundWorks;
          if (works.isEmpty) {
            return Center(
              child: Text(
                '当前没有后台工作',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            );
          }
          return ListView.separated(
            key: const ValueKey('background-works-list'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: works.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (_, i) {
              final w = works[i];
              final workId = '${w['workId'] ?? ''}';
              final kind = '${w['kind'] ?? ''}';
              final status = '${w['status'] ?? ''}';
              final (color, statusLabel) = _statusOf(context, status);
              final cancellable =
                  status == 'running' && w['cancellable'] != false;
              return Padding(
                key: ValueKey('background-work-$workId'),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                      _iconOf(kind),
                      size: 16,
                      color: status == 'running'
                          ? context.colors.running
                          : color,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${w['title'] ?? workId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        translate: false,
                        style: TextStyle(
                          fontSize: AppType.uiBase,
                          color: context.colors.foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: color,
                      ),
                    ),
                    if (cancellable)
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: IconButton(
                          key: ValueKey('background-work-cancel-$workId'),
                          padding: EdgeInsets.zero,
                          alignment: Alignment.center,
                          iconSize: 16,
                          tooltip: '取消',
                          onPressed: () => onCancel(sessionId, workId),
                          icon: Icon(
                            Icons.close,
                            size: 16,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
