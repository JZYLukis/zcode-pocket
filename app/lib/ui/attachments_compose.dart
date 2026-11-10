import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../core/payload_guard.dart';

/// 待发送附件（阶段 3 第三段附件上传）。
///
/// 官方边界（chatAttachments.ts:37-44 + put 侧 attachmentMaxBytes）：
/// 最多 8 个、单文件 20MiB；无类型限制（file input 无 accept）。
/// 草稿态无 sessionId 时停留 waitingSession——发送点击时先建空会话
/// 再上传（官方 SessionPane.tsx:3520+ 兜底路径的手机端适配：官方预热
/// 会话被弃置会留空任务卡，我们改为发送时一次性完成，避免污染任务列表）。
class PendingAttachment {
  final String id;
  final String fileName;
  final String mime;
  Uint8List bytes;

  /// -1 = 排队/waitingSession，0..1 = 上传中，1 = 完成。
  double progress;
  String? error;

  /// 上传结果（官方 AttachmentRef：ref/fileName/mime/bytes）。
  Map<String, dynamic>? uploaded;

  /// 草稿恢复：原文件只有本地字节、没有上传引用，跨重启无法保证可取回。
  bool sourceUnavailable;
  int? persistedByteSize;

  PendingAttachment({
    required this.id,
    required this.fileName,
    required this.mime,
    required this.bytes,
    this.progress = -1,
    this.error,
    this.uploaded,
    this.sourceUnavailable = false,
    this.persistedByteSize,
  });

  bool get ready => uploaded != null && error == null;
  int get effectiveByteSize =>
      persistedByteSize ?? intOf(uploaded?['bytes']) ?? bytes.length;

  bool get isImage => mime.startsWith('image/');

  /// 可标注（6.6④）：本地字节在手的图片（恢复图取回字节后同样可标）。
  bool get annotatable => isImage && bytes.isNotEmpty && error == null;
}

const int kMaxChatAttachments = 8;
const int kAttachmentMaxBytes = 20 * 1024 * 1024;

String humanBytes(int n) {
  if (n >= 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '$n B';
}

/// 输入卡上方的待发送附件区（2026-10-22 验收回填⑩：用户反馈竖排观感差，
/// 改微信/Telegram 范式——**图片=3 列方形缩略图网格**（上传进度/失败
/// 重试/移除角标），非图片文件=官方 attachments.tsx inline 单行 chip；
/// 区域限高滚动（8 张图最多 3 行可见，输入卡不再把输入框顶到键盘底下）。
class PendingAttachmentChips extends StatelessWidget {
  final List<PendingAttachment> attachments;
  final void Function(String id) onRemove;
  final void Function(String id) onRetry;

  /// 截图圈点标注入口（6.6④）：图片字节在手时进标注编辑器。
  final void Function(String id)? onAnnotate;

  const PendingAttachmentChips({
    super.key,
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
    this.onAnnotate,
  });

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final images = [
      for (final a in attachments)
        if (a.isImage) a,
    ];
    final files = [
      for (final a in attachments)
        if (!a.isImage) a,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 328),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (images.isNotEmpty)
                _ImageGrid(
                  images: images,
                  onRemove: onRemove,
                  onRetry: onRetry,
                  onAnnotate: onAnnotate,
                ),
              if (files.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final a in files) _fileChip(context, a)],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileChip(BuildContext context, PendingAttachment a) {
    return Container(
      key: ValueKey('pending-attachment-${a.id}'),
      constraints: const BoxConstraints(minHeight: 32, maxWidth: 220),
      padding: const EdgeInsetsDirectional.only(start: 8, end: 2),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: a.error == null
              ? context.colors.border
              : context.colors.destructive.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            a.error != null
                ? Icons.error_outline
                : (a.ready ? Icons.check_circle : Icons.attach_file),
            size: 14,
            color: a.error != null
                ? context.colors.destructive
                : (a.ready
                      ? context.colors.linkBlue
                      : context.colors.foregroundSubtle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: InkWell(
              key: ValueKey('pending-attachment-retry-${a.id}'),
              onTap: a.error != null && !a.sourceUnavailable
                  ? () => onRetry(a.id)
                  : null,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text.rich(
                  TextSpan(
                    text: a.fileName,
                    children: [
                      TextSpan(
                        text:
                            ' · ${a.error != null ? (a.sourceUnavailable ? a.error! : '上传失败，点此重试') : (a.ready ? humanBytes(a.effectiveByteSize) : (a.progress < 0 ? '待发' : '${(a.progress * 100).toInt()}%'))}',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtlest,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: AppType.uiCaption),
                ),
              ),
            ),
          ),
          InkWell(
            key: ValueKey('pending-attachment-remove-${a.id}'),
            onTap: () => onRemove(a.id),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 14,
                color: context.colors.foregroundSubtlest,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 图片附件缩略图网格（验收回填⑩：3 列方形，官方 grid 变体
/// size-24 方块观感的手机化）。
class _ImageGrid extends StatelessWidget {
  final List<PendingAttachment> images;
  final void Function(String id) onRemove;
  final void Function(String id) onRetry;
  final void Function(String id)? onAnnotate;

  const _ImageGrid({
    required this.images,
    required this.onRemove,
    required this.onRetry,
    this.onAnnotate,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        const gap = 8.0;
        final cell = ((cons.maxWidth - gap * 2) / 3).clamp(80.0, 140.0);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final a in images)
              SizedBox(
                key: ValueKey('pending-attachment-${a.id}'),
                width: cell,
                height: cell,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: a.error != null
                          ? Container(
                              color: context.colors.destructive.withValues(
                                alpha: 0.08,
                              ),
                              alignment: Alignment.center,
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.error_outline,
                                      size: 20,
                                      color: context.colors.destructive,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      a.sourceUnavailable
                                          ? '源文件已失效\n请重新选择'
                                          : '上传失败 点此重试',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        color: context.colors.destructive,
                                      ),
                                    ),
                                    Text(
                                      a.fileName,
                                      translate: false,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        color: context.colors.destructive,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : a.bytes.isEmpty && a.ready
                          ? Container(
                              color: context.colors.surface,
                              alignment: Alignment.center,
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.cloud_done_outlined,
                                      size: 20,
                                      color: context.colors.linkBlue,
                                    ),
                                    Text(
                                      '已上传 · ${humanBytes(a.effectiveByteSize)}',
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        color: context.colors.foregroundSubtle,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: Text(
                                        a.fileName,
                                        translate: false,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: AppType.uiXs,
                                          color:
                                              context.colors.foregroundSubtle,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : Image(
                              image: MemoryImage(a.bytes),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => Container(
                                color: context.colors.surface,
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 20,
                                  color: context.colors.foregroundSubtlest,
                                ),
                              ),
                            ),
                    ),
                    // 失败态整格可点重试；上传中遮罩显示进度。
                    if (a.error != null && !a.sourceUnavailable)
                      Positioned.fill(
                        child: InkWell(
                          key: ValueKey('pending-attachment-retry-${a.id}'),
                          onTap: () => onRetry(a.id),
                        ),
                      ),
                    if (a.error == null && !a.ready)
                      Positioned.fill(
                        child: Container(
                          color: context.colors.foreground.withValues(
                            alpha: 0.45,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            a.progress < 0
                                ? '待发'
                                : '${(a.progress * 100).toInt()}%',
                            style: TextStyle(
                              fontSize: AppType.uiCaption,
                              fontWeight: FontWeight.w600,
                              color: context.colors.card,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        key: ValueKey('pending-attachment-remove-${a.id}'),
                        onTap: () => onRemove(a.id),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: context.colors.foreground.withValues(
                              alpha: 0.55,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: context.colors.card,
                          ),
                        ),
                      ),
                    ),
                    // 标注入口（6.6④）：左下角小画笔，仅在可标注态出现。
                    if (a.annotatable && onAnnotate != null)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: GestureDetector(
                          key: ValueKey('pending-attachment-annotate-${a.id}'),
                          onTap: () => onAnnotate?.call(a.id),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: context.colors.foreground.withValues(
                                alpha: 0.55,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.edit,
                              size: 13,
                              color: context.colors.card,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
