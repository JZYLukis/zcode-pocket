// 产物分享 UI 编排（早前批次）：进度弹窗（可取消）+内存内容
// 直分享。核心下载/分享逻辑在 core/artifact_share.dart（可单测）。
//
// 两个入口：
// - shareArtifactRemotely：产物行「分享」——回源全量拉取（ArtifactRead
//   分块协议无总长，进度为不定条+已收字节数）；
// - shareBytesAsFile：预览页「分享」——内容已完整在内存（预览入口即
//   完整性闸：图片 16MiB 上限、文本 8 块截断时不给入口），直接落盘
//   不再回源。
//
// 磁盘端口 [shareDisk]：testWidgets 假区内真实磁盘 IO 永不完成（决策记录
// 0069 教训）——旅程测试注入内存桩只验到通道边界，真实磁盘往返由
// 纯逻辑组真文件覆盖（test/artifact_share_test.dart downloadArtifactToFile 组）。
import 'dart:io';


import 'package:flutter/material.dart' hide Text;
import 'package:path_provider/path_provider.dart';

import '../core/artifact_share.dart';
import '../core/localized_text.dart';
import '../core/theme.dart';

/// 分享磁盘端口（默认真实实现；测试缝）。
class ArtifactShareDiskPort {
  const ArtifactShareDiskPort();

  Future<void> ensureTarget(File target) async {
    await target.parent.create(recursive: true);
  }

  Future<void> writeBytes(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
  }

  /// 读文件头（后缀嗅探用）。端口化原因：testWidgets 假区内真实磁盘
  /// IO 永不完成（——连异常都不投递），内存桩须替代。
  Future<List<int>> readHead(File target, [int limit = 1024]) async {
    final head = <int>[];
    await for (final chunk in target.openRead(0, limit)) {
      head.addAll(chunk);
    }
    return head;
  }

  /// 重命名（后缀嗅探补名）。真实实现先删同名残留（Windows rename
  /// 对已存在目标报错）；内存桩挪 map 键。
  Future<File> renameTo(File from, String newName) async {
    final moved = File('${from.parent.path}${Platform.pathSeparator}$newName');
    if (await moved.exists()) await moved.delete();
    return await from.rename(moved.path);
  }

  Future<int> download({
    required Future<dynamic> Function(int offset) read,
    required File target,
    void Function(int received)? onProgress,
    bool Function()? isCancelled,
    int maxBytes = kMaxArtifactShareBytes,
  }) {
    return downloadArtifactToFile(
      read: read,
      target: target,
      onProgress: onProgress,
      isCancelled: isCancelled,
      maxBytes: maxBytes,
    );
  }
}

@visibleForTesting
ArtifactShareDiskPort shareDisk = const ArtifactShareDiskPort();

/// 字节数人话（进度行显示）。
String formatArtifactBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    final m = bytes / (1024 * 1024);
    return '${m >= 10 ? m.toStringAsFixed(0) : m.toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// 产物行「分享」：进度弹窗全量拉取 → 成功即调系统分享面板。
/// 弹窗关闭返回 true=文件就绪（分享已由本函数发起）；false=取消/失败
/// （用户已在弹窗内看到错误）。
Future<void> shareArtifactRemotely(
  BuildContext context, {
  required String displayName,
  required Future<dynamic> Function(int offset) read,
}) async {
  final cache = await getTemporaryDirectory();
  var target = artifactShareTarget(cache, displayName);
  await shareDisk.ensureTarget(target);
  if (!context.mounted) return;
  final ready = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ArtifactShareDialog(read: read, target: target),
  );
  if (ready != true) return;
  // 后缀兜底（2026-11-14 验收）：title 无扩展名时按文件头魔数补——
  // xlsx/pptx/pdf 无后缀在接收端打不开（agent 提示词同批已加 title=
  // 带后缀文件名，本层为不依赖 agent 自觉的兜底）。
  try {
    final head = await shareDisk.readHead(target);
    final base = target.path.split(Platform.pathSeparator).last;
    final fixed = ensureArtifactExtension(base, head);
    if (fixed != base) {
      target = await shareDisk.renameTo(target, fixed);
    }
  } catch (_) {/* 嗅探/改名失败=按原名分享，不阻断 */}
  final ok = await shareArtifactFile(target.path);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('分享失败'))),
    );
  }
}

/// 预览页「分享」：内存内容直落盘并调分享面板。
Future<void> shareBytesAsFile(
  BuildContext context,
  String displayName,
  List<int> bytes,
) async {
  try {
    final cache = await getTemporaryDirectory();
    // 后缀兜底（与产物行下载同款）：内存字节直接嗅探补扩展名。
    final name = ensureArtifactExtension(
      sanitizeArtifactFileName(displayName),
      bytes.take(1024).toList(),
    );
    final target = artifactShareTarget(cache, name);
    await shareDisk.writeBytes(target, bytes);
    final ok = await shareArtifactFile(target.path);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('分享失败'))),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('分享失败')}：$e')),
      );
    }
  }
}

/// 全量拉取进度弹窗（同 update _DownloadDialog 骨架：PopScope 返回键=
/// 取消；错误内联+重试）。分块协议无总长——不定进度条+已收字节数。
class ArtifactShareDialog extends StatefulWidget {
  const ArtifactShareDialog({
    super.key,
    required this.read,
    required this.target,
  });

  final Future<dynamic> Function(int offset) read;
  final File target;

  @override
  State<ArtifactShareDialog> createState() => _ArtifactShareDialogState();
}

class _ArtifactShareDialogState extends State<ArtifactShareDialog> {
  int _received = 0;
  String? _error; // null=进行中
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _cancelled = false;
    setState(() {
      _error = null;
      _received = 0;
    });
    _run();
  }

  Future<void> _run() async {
    try {
      await shareDisk.download(
        read: widget.read,
        target: widget.target,
        onProgress: (received) {
          if (mounted) setState(() => _received = received);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      // 对抗审查 A-（2026-11-14）：取消在最终块在飞时置位——下载
      // 本身完成了，但用户意图是取消，不得弹分享。
      if (_cancelled) {
        Navigator.of(context).pop(false);
        return;
      }
      Navigator.of(context).pop(true);
    } on ArtifactShareException catch (e) {
      if (!mounted) return;
      if (e.reason == 'cancelled') {
        Navigator.of(context).pop(false);
        return;
      }
      setState(() {
        _error = e.reason == 'oversized'
            ? tr('产物过大（超过 150MB），无法分享')
            // 人话化（A-）：incomplete→不完整。
            : e.reason.startsWith('read-failed(incomplete')
                ? tr('产物内容不完整，已丢弃')
                : '${tr('下载产物失败：')}${e.reason}';
      });
    }
  }

  /// 取消=立即关弹窗（A-：此前只置标志，read 在飞时（RPC 30s 超时
  /// 窗口）用户面对死界面连返回键都弹不掉；后台循环凭标志自行清理）。
  void _cancel() {
    _cancelled = true;
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 同 update ②M2：系统返回键=取消，下载不得转后台。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // 系统返回键=取消并立即关（A-：错误态原先返回键是死的）。
        if (!didPop) _cancel();
      },
      child: AlertDialog(
        // 错误态标题不再谎称进行中（A-）。
        title: Text(_error == null ? tr('正在获取产物…') : tr('下载失败')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              minHeight: 6,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: context.colors.destructive),
              )
            else
              Text(formatArtifactBytes(_received)),
          ],
        ),
        actions: [
          if (_error != null)
            FilledButton(
              onPressed: () {
                _cancelled = false;
                _start();
              },
              child: Text(tr('重试')),
            ),
          TextButton(
            onPressed: () {
              if (_error != null) {
                Navigator.of(context).pop(false);
              } else {
                _cancel();
              }
            },
            child: Text(_error == null ? tr('取消') : tr('关闭')),
          ),
        ],
      ),
    );
  }
}
