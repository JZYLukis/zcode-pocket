/// 批次4（2026-10-19 审查）共享组件库：把各页逐字重复的空态/错误态/
/// 加载态/分区标题/弹层骨架/确认对话框收敛为一份。组件只做"同一视觉
/// 的单源"，不引入新样式——各页采用时视觉零变化。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;

import '../core/theme.dart';

/// 一键复制小按钮（2026-10-23 用户反馈批⑧）：桌面端消息行/代码块
/// 右上角都有复制（官方 CopyRowAction ConversationRowView.tsx:182 /
/// CodeBlockCopyButton code-block.tsx:454），官方手机远控形态=常显
/// action bar（compactForRemoteControl 分支）。点击→图标换对勾
/// 1.2s+SnackBar 反馈（官方同款节奏）。命中区 44（触控四件标准）。
class CopyIconButton extends StatefulWidget {
  const CopyIconButton({
    super.key,
    required this.text,
    this.tooltip = '复制',
    this.snackText = '已复制',
    this.iconSize = 15,
    this.compact = false,
  });

  final String text;

  /// SnackBar 文案（代码块用「代码已复制」等差异化提示）。
  final String snackText;
  final String tooltip;
  final double iconSize;

  /// 紧凑档（2026-10-23 用户反馈：消息尾常显按钮突兀+占位——44 盒
  /// 收到 28、图标 12，贴文字下沿；触控 44 纪律此处按用户拍板让位
  /// 紧凑观感，与 Paseo 28 控件同尺寸）。代码块右上角仍用默认 44 档。
  final bool compact;

  @override
  State<CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<CopyIconButton> {
  Timer? _resetTimer;
  bool _copied = false;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: widget.tooltip,
      icon: Icon(
        _copied ? Icons.check : Icons.copy_outlined,
        size: widget.iconSize,
      ),
      color: context.colors.foregroundSubtlest,
      padding: EdgeInsets.zero,
      constraints: widget.compact
          ? const BoxConstraints(minWidth: 28, minHeight: 28)
          : const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: widget.text.isEmpty
          ? null
          : () async {
              // await+失败反馈（失败
              // 时勾仍亮 1.2s 且无提示。
              var ok = true;
              try {
                await Clipboard.setData(ClipboardData(text: widget.text));
              } catch (_) {
                ok = false;
              }
              if (!mounted) return;
              // this.context（State 的）：build 参数 context 在 async
              // 闭包里与 mounted guard 不关联会触发 lint。
              ScaffoldMessenger.of(this.context).showSnackBar(
                SnackBar(
                  content: Text(ok ? widget.snackText : '复制失败，请重试'),
                  duration: const Duration(milliseconds: 1200),
                ),
              );
              if (ok) {
                setState(() => _copied = true);
                _resetTimer?.cancel();
                _resetTimer = Timer(const Duration(milliseconds: 1200), () {
                  if (mounted) setState(() => _copied = false);
                });
              }
            },
    );
  }
}

/// 空态提示（原 task_center _EmptyHint 同视觉）。
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const AppEmptyState({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: context.colors.foregroundSubtlest),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.colors.foregroundSubtle,
              fontSize: AppType.uiCaption,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误态（图标+文案+可选重试按钮）。
class AppErrorState extends StatelessWidget {
  final String message;
  final String? hint;
  final VoidCallback? onRetry;
  const AppErrorState({
    super.key,
    required this.message,
    this.hint,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 40,
            color: context.colors.foregroundSubtlest,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(
              color: context.colors.destructive,
              fontSize: AppType.uiCaption,
            ),
            textAlign: TextAlign.center,
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: TextStyle(
                color: context.colors.foregroundSubtlest,
                fontSize: AppType.uiXs,
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 加载态（转圈+一行说明）。
class AppLoading extends StatelessWidget {
  final String text;
  const AppLoading(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              color: context.colors.foregroundSubtle,
              fontSize: AppType.uiCaption,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区标题（原 task_center _SectionHeader 同视觉）。
class AppSectionHeader extends StatelessWidget {
  final String text;
  const AppSectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppType.uiSm,
          color: context.colors.foregroundSubtle,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 弹层骨架：isScrollControlled + 限高 + 滚动容器（批次1 两弹层同款
/// 范式组件化——字体放大/条目增多时顶部选项始终可达）。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxHeightFactor = 0.7,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * maxHeightFactor,
        ),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: builder(sheetContext),
        ),
      ),
    ),
  );
}

/// 确认对话框（删除类破坏性操作统一：红确认键+取消；文案由调用方给）。
/// 批次4：破坏性确认按下带触感反馈（审查无障碍项）。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '删除',
  bool destructive = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: context.colors.destructive)
              : null,
          onPressed: () {
            if (destructive) HapticFeedback.mediumImpact();
            Navigator.pop(dialogContext, true);
          },
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}
