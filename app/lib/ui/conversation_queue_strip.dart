import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/conversation.dart';

class QueueStrip extends StatelessWidget {
  final ConversationState state;
  final String? sessionId;

  const QueueStrip({required this.state, required this.sessionId});

  Future<void> _action(
    BuildContext context,
    Future<dynamic> Function() run,
  ) async {
    try {
      await run();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('排队操作失败：$e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = state.queueItems;
    if (items.isEmpty || sessionId == null) return const SizedBox.shrink();
    final autoDrain = state.autoDrain;
    return Container(
      decoration: BoxDecoration(
        color: context.colors.header.withValues(alpha: 0.95),
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.hourglass_top,
                size: 13,
                color: context.colors.foregroundSubtle,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '排队中 (${items.length})${autoDrain ? ' · 回合结束后自动发送' : ''}',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
              // 速赢#2（WR）：autoDrain 开关（桌面 ConversationQueuePanel 同款）。
              SizedBox(
                width: 34,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  // D2-07：tooltip 非 Text 组件需显式 tr()。
                  tooltip: autoDrain ? tr('关闭自动发送') : tr('回合结束后自动发送'),
                  icon: Icon(
                    autoDrain ? Icons.autorenew : Icons.autorenew_outlined,
                    color: autoDrain
                        ? context.colors.running
                        : context.colors.foregroundSubtlest,
                  ),
                  onPressed: () => _action(
                    context,
                    () =>
                        AppStateScope.of(context)
                            .setAutoDrain(sessionId!, !autoDrain),
                  ),
                ),
              ),
            ],
          ),
          for (final item in items.take(2))
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${item['text'] ?? ''}',
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    tooltip: tr('编辑'),
                    icon: const Icon(Icons.edit_outlined),
                    color: context.colors.foregroundSubtlest,
                    onPressed: () async {
                      final controller = TextEditingController(
                        text: '${item['text'] ?? ''}',
                      );
                      final text = await showDialog<String>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('编辑排队消息'),
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                            maxLines: 4,
                            style: const TextStyle(
                              fontSize: AppType.mobileInputSafe,
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(
                                dialogContext,
                                controller.text.trim(),
                              ),
                              child: const Text('保存'),
                            ),
                          ],
                        ),
                      );
                      controller.dispose();
                      if (text != null && text.isNotEmpty) {
                        await _action(
                          context,
                          () => AppStateScope.of(context).editQueueItem(
                            sessionId!,
                            '${item['queueItemId']}',
                            text,
                          ),
                        );
                      }
                    },
                  ),
                ),
                SizedBox(
                  width: 44,
                  height: 40,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    tooltip: tr('立即发送'),
                    icon: const Icon(Icons.send_outlined),
                    color: context.colors.foregroundSubtle,
                    onPressed: () => _action(
                      context,
                      () => AppStateScope.of(context)
                          .sendQueuedNow(sessionId!, '${item['queueItemId']}'),
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  height: 40,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    tooltip: tr('删除'),
                    icon: const Icon(Icons.delete_outline),
                    color: context.colors.foregroundSubtlest,
                    onPressed: () => _action(
                      context,
                      () => AppStateScope.of(
                        context,
                      ).deleteQueueItem(sessionId!, '${item['queueItemId']}'),
                    ),
                  ),
                ),
              ],
            ),
          if (items.length > 2)
            Text(
              // D2-07：对齐官方 pattern「^… 还有 N 条$」的空格
              // 口径（此前源串无空格恒不命中）。
              '… 还有 ${items.length - 2} 条',
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtlest,
              ),
            ),
        ],
      ),
    );
  }
}

/// 输入卡（2026-10-17 对齐桌面 composer 结构，移动端布局）：
/// 圆角卡片 = 上半多行输入 + 分隔线 + 底部工具栏行。
/// 工具栏：`[+] 添加`｜`模型 · 档˅` `●状态` `🎤` `发送/停止`——模型与思考
/// 档合并为一枚药丸（用户 2026-10-19 拍板，参考 Claude 系 App 连排格式：
/// 二者本是同一提交单元 modelSelection，合并省一枚药丸的外屏宽度），
/// 点开同页选择（上半模型列表+底部档位 chips）。官方手机端是桌面挤压
/// 无移动特化、zemote 用 +宫格——取两者之长。
/// 只读会话的底部占位条（子代理下钻视图）：不可输入，仅浏览。
