// 产物分享·下载与落盘（早前批次）。
//
// 工作流内容产物经 workflowRunArtifactRead（512KiB base64 分块）全量
// 拉取流式写缓存文件，再由原生 companion/share shareFile 调系统分享
// 面板（方案 A：私有目录+分享面板——零存储权限，用户经面板「保存到
// 文件」自选落点）。与工作区文件预览的取舍（协议无任意
// 文件字节通道）不同轨——ArtifactRead 是协议仅有的字节通道（预览已在
// 用），本文件只是把预览的 8 块显示上限放开为全量+大小硬顶。
//
// 仅前台分享（同应用内更新原则）；取消/超限/读失败一律删除半截文件。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 大小硬上限（与 kMaxUpdateBytes 同级：中继 WSS 分块通道下拉更大
/// 产物体验已劣化，早拒绝比拖满磁盘诚实）。
const kMaxArtifactShareBytes = 150 * 1024 * 1024;

/// 分块大小——与预览路径同款（workflow_runs_page _openArtifact）。
const kArtifactShareBlockBytes = 512 * 1024;

class ArtifactShareException implements Exception {
  final String reason;
  const ArtifactShareException(this.reason);
  @override
  String toString() => 'ArtifactShareException($reason)';
}

/// 文件名净化：Windows/FAT 非法字符与控制字符→下划线；剥首尾空白与
/// 点（Windows 不允许结尾点/空格）；空/全非法→ artifact 兜底；超长截
/// 64 字符且保住扩展名。
String sanitizeArtifactFileName(String name) {
  var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  n = n.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (n.isEmpty) return 'artifact.bin';
  if (n.length > 64) {
    final dot = n.lastIndexOf('.');
    final ext = dot > 0 && n.length - dot <= 10 ? n.substring(dot) : '';
    n = '${n.substring(0, 64 - ext.length)}$ext';
  }
  return n;
}

/// 全量分块拉取产物到 [target]（覆盖写）。[read] 回调协议同
/// readArtifactBlocks：传 offset，返回 {dataBase64, nextOffset}——
/// dataBase64 空/nextOffset 不前进即结束。返回写入字节数。
/// 取消（[isCancelled]）/超限（[maxBytes]）/读失败：关闭并删除半截
/// 文件后抛 [ArtifactShareException]（cancelled/oversized/
/// read-failed(原因)）。
Future<int> downloadArtifactToFile({
  required Future<dynamic> Function(int offset) read,
  required File target,
  void Function(int received)? onProgress,
  bool Function()? isCancelled,
  int maxBytes = kMaxArtifactShareBytes,
}) async {
  var received = 0;
  var offset = 0;
  // 对抗审查 A-M2/（2026-11-14）：协议响应必带 totalBytes——拿它做
  // 完整性闸（空块/nextOffset 异常提前收尾≠成功，半截文件不得冒充
  // 完整进分享）；块数刹车对齐官方 MAX_CHUNKS 思路（自然上限
  // 150MB/512KiB=300 块，翻倍刹车防 1 字节/块的病态推进）。
  int? totalBytes;
  var blocks = 0;
  final sink = target.openWrite(mode: FileMode.write);
  var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  try {
    while (true) {
      if (isCancelled?.call() ?? false) {
        throw const ArtifactShareException('cancelled');
      }
      if (++blocks > 600) {
        throw const ArtifactShareException('read-failed(block-limit)');
      }
      final res = await read(offset);
      if (res is Map) {
        final tb = (res['totalBytes'] as num?)?.toInt();
        if (tb != null && tb > 0) totalBytes = tb;
      }
      final b64 = '${(res is Map ? res['dataBase64'] : '') ?? ''}';
      if (b64.isEmpty) break;
      final chunk = base64.decode(b64);
      sink.add(chunk);
      received += chunk.length;
      if (received > maxBytes) {
        throw const ArtifactShareException('oversized');
      }
      final now = DateTime.now();
      // 100ms 合帧节流（update_download 同款）。
      if (onProgress != null &&
          now.difference(lastNotify).inMilliseconds >= 100) {
        lastNotify = now;
        onProgress(received);
      }
      final next =
          (res is Map ? (res['nextOffset'] as num?)?.toInt() : null) ?? -1;
      if (next <= offset || next <= 0) break;
      offset = next;
    }
    await sink.flush();
    await sink.close();
  } on Object catch (e) {
    // 半截文件不落残留（cache 目录虽会被系统清理，主动删更干净）。
    try {
      await sink.close();
    } catch (_) {}
    try {
      await target.delete();
    } catch (_) {}
    if (e is ArtifactShareException) rethrow;
    throw ArtifactShareException('read-failed($e)');
  }
  // 完整性闸：协议声明 totalBytes 而实收不足=半截文件（A-M2：空块/
  // nextOffset 异常被当成功收尾是最坏形态——用户以为拿到完整产物）。
  if (totalBytes != null && received != totalBytes) {
    try {
      await target.delete();
    } catch (_) {}
    throw ArtifactShareException('read-failed(incomplete $received/$totalBytes)');
  }
  onProgress?.call(received);
  return received;
}

/// 调系统分享面板（原生 companion/share shareFile：ACTION_SEND +
/// FileProvider 只读授权）。返回 false=原生侧调起失败。
Future<bool> shareArtifactFile(String path) async {
  try {
    return await const MethodChannel('companion/share')
            .invokeMethod<bool>('shareFile', {'path': path}) ??
        false;
  } on PlatformException {
    return false;
  }
}

/// 分享缓存文件路径（cache/artifacts/，FileProvider 只授权该子目录）。
File artifactShareTarget(Directory cacheDir, String displayName) {
  final dir = Directory('${cacheDir.path}${Platform.pathSeparator}artifacts');
  return File(
    '${dir.path}${Platform.pathSeparator}'
    '${sanitizeArtifactFileName(displayName)}',
  );
}

/// 文件名后缀兜底（2026-11-14 真机验收：产物 title 可能是无后缀中文
/// 名——"测试表格（Excel·openpyxl）"，xlsx/pptx/pdf 无后缀在接收端
/// 打不开；png 靠魔数/md 靠文本侥幸）。已有合法扩展名=原样返回（不
/// 覆盖 agent 命名）；无扩展名=按文件头魔数补（sniffImageMagic 同族，
/// 扩展到 PDF/OOXML/zip）。
String ensureArtifactExtension(String fileName, List<int> head) {
  final name = fileName.trim();
  final dot = name.lastIndexOf('.');
  // 对抗审查 A-：扩展名须字母开头（纯数字尾巴多为版本号/日期，
  // '报告.2026' 不该阻断嗅探）。
  final hasExt =
      dot > 0 && name.length - dot <= 10 && dot < name.length - 1
          ? RegExp(r'^[A-Za-z][A-Za-z0-9]{0,8}$')
              .hasMatch(name.substring(dot + 1))
          : false;
  if (hasExt) return name;
  final ext = _sniffFileExt(head);
  return ext == null ? name : '$name.$ext';
}

String? _sniffFileExt(List<int> head) {
  if (head.length < 4) return null;
  bool eq(int start, List<int> magic) {
    if (head.length < start + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[start + i] != magic[i]) return false;
    }
    return true;
  }

  if (eq(0, [0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (eq(0, [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (eq(0, [0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (eq(0, [0x42, 0x4D])) return 'bmp';
  if (eq(0, [0x52, 0x49, 0x46, 0x46]) &&
      head.length >= 12 &&
      eq(8, [0x57, 0x45, 0x42, 0x50])) return 'webp';
  // 对抗审查 A-/A-（2026-11-14）：窗口 1024→16384——真实 docx/pptx
  // 的家族目录名在 1.7-1.8KB（审查员用仓内真实 fixture 字节探针实证，
  // 1024 窗口会把 pptx/docx 补成 .zip 打不开）；PK 判定先于 %PDF（zip
  // 首条目是 stored PDF 时魔数是更强证据）；家族标记加非字母数字边界
  //（'maxl/' 不误判 xlsx）。
  final window = String.fromCharCodes(head.take(16384));
  if (eq(0, [0x50, 0x4B, 0x03, 0x04])) {
    final family = RegExp(r'(^|[^A-Za-z0-9])(xl|ppt|word)/')
        .firstMatch(window);
    if (family != null) {
      switch (family.group(2)) {
        case 'xl':
          return 'xlsx';
        case 'ppt':
          return 'pptx';
        case 'word':
          return 'docx';
      }
      return 'zip';
    }
    return 'zip';
  }
  // PDF 允许前导垃圾（官方口径 %PDF 可在任意偏移）；在 PK 之后判定。
  if (window.contains('%PDF')) return 'pdf';
  return null;
}
