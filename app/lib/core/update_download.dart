// 应用内更新——下载与校验（in-app-update-1）。
//
// 流式下载（Range 断点续传）→ 完整文件流式 SHA-256 → 与官方 digest
// 比对。校验是信任锚：直连或镜像下载的字节对不上官方哈希一律拒装。
// 仅前台下载（切后台由调用方取消）；不引 http/dio。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 测试缝：镜像前缀覆盖。
@visibleForTesting
String? debugMirrorPrefixOverride;

const kDefaultMirrorPrefix = 'https://ghproxy.com/';

/// 对抗审查 ②：下载大小硬上限（防恶意/异常响应写满磁盘；官方包
/// 现 ~35MB，上限留 4 倍余量）。
const kMaxUpdateBytes = 150 * 1024 * 1024;

class UpdateDownloadException implements Exception {
  final String reason;
  const UpdateDownloadException(this.reason);
  @override
  String toString() => 'UpdateDownloadException($reason)';
}

class UpdateDownload {
  UpdateDownload({@visibleForTesting HttpClient? client})
      : _client = client ?? HttpClient()..connectionTimeout = const Duration(seconds: 10);

  final HttpClient _client;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// ②：真正中止在途请求并释放连接（此前 cancel 只置 flag——服务器
  /// 挂起时 await for 永不结束，请求与 socket 永久悬挂）。
  void dispose() {
    _cancelled = true;
    _client.close(force: true);
  }

  /// 下载 [url]（直连失败自动改走镜像）到 [target]。
  /// onProgress(已收字节, 总字节|null)。支持从 [target] 已有字节续传
  /// （Range）——续传前提：服务器对 Range 返回 206；返回 200 则从头下。
  /// 对抗审查 ②M3：服务器 416=本地已有字节≥资源大小（此前直抛=完整
  /// 文件场景重试恒 416 死锁）。抛本异常由调用方把现有文件交校验。
  static bool isRangeSatisfied(Object e) =>
      e is UpdateDownloadException && e.reason == 'http-416';

  Future<void> download(
    String url,
    File target, {
    void Function(int received, int? total)? onProgress,
  }) async {
    _cancelled = false;
    Object? directError;
    try {
      await _downloadFrom(url, target, onProgress: onProgress);
      return;
    } on UpdateDownloadException catch (e) {
      // 确定性失败不进镜像（cancelled=用户意图；oversized=大小上限；
      // http-416=Range 已满足——重试同结果，交调用方处置）。
      if (_cancelled || e.reason == 'oversized' || e.reason == 'http-416') {
        rethrow;
      }
      directError = e;
    } on Object catch (e) {
      // 网络/超时等原生异常也走镜像兜底（直连不可达是常态场景）。
      if (_cancelled) {
        throw const UpdateDownloadException('cancelled');
      }
      directError = e;
    }
    // 镜像兜底（同一 URL 前缀拼接；SHA256 校验保证镜像可信度）。
    if (_cancelled) {
      throw const UpdateDownloadException('cancelled');
    }
    final mirror = debugMirrorPrefixOverride ?? kDefaultMirrorPrefix;
    try {
      await _downloadFrom('$mirror$url', target, onProgress: onProgress);
    } on UpdateDownloadException {
      rethrow;
    } catch (e) {
      throw UpdateDownloadException('mirror-failed($directError/$e)');
    }
  }

  Future<void> _downloadFrom(
    String url,
    File target, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final existed = await target.exists() ? await target.length() : 0;
    final req = await _client.getUrl(Uri.parse(url)).timeout(
          const Duration(seconds: 12),
        );
    // GitHub 资产 302 到下载域——必须跟随重定向。
    req.followRedirects = true;
    req.maxRedirects = 5;
    req.headers.set('User-Agent', 'zcode-pocket-updater');
    if (existed > 0) {
      req.headers.set('Range', 'bytes=$existed-');
    }
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode == 416) {
      res.drain<void>();
      // ②M3：本地已有 ≥ 资源大小（多半是上次下载完整但用户取消了安装）
      // ——映射为专用错误，调用方应把现有文件交 SHA 校验而非死循环重试。
      throw const UpdateDownloadException('http-416');
    }
    if (res.statusCode != 200 && res.statusCode != 206) {
      res.drain<void>();
      throw UpdateDownloadException('http-${res.statusCode}');
    }
    final contentRange = res.headers.value(HttpHeaders.contentRangeHeader);
    final contentLengthHeader =
        res.headers.value(HttpHeaders.contentLengthHeader);
    final resumed = res.statusCode == 206 && contentRange != null;
    if (!resumed && existed > 0) {
      // 服务器不支持续传（回 200）：重写文件。
      await target.writeAsBytes([], flush: true);
    }
    final totalFromRange = _totalFromContentRange(contentRange);
    final total = totalFromRange ??
        (contentLengthHeader != null
            ? int.tryParse(contentLengthHeader)
            : null);
    var received = resumed ? existed : 0;
    if (total != null && received > total) {
      // 本地残留比远端还大（异常态）：从头下。
      await target.writeAsBytes([], flush: true);
      received = 0;
    }
    final sink = await target.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in res) {
        if (_cancelled) {
          throw const UpdateDownloadException('cancelled');
        }
        sink.add(chunk);
        received += chunk.length;
        // ②：大小硬上限（超限即停——恶意/异常响应不得写满磁盘）。
        if (received > kMaxUpdateBytes) {
          await sink.flush();
          await sink.close();
          await target.delete().catchError((_) => target);
          throw const UpdateDownloadException('oversized');
        }
        final now = DateTime.now();
        // 100ms 合帧节流（conversation_page 上传进度同款）。
        if (onProgress != null &&
            now.difference(lastNotify).inMilliseconds >= 100) {
          lastNotify = now;
          onProgress(received, total);
        }
      }
      await sink.flush();
      onProgress?.call(received, total);
    } finally {
      await sink.close();
    }
  }

  int? _totalFromContentRange(String? contentRange) {
    if (contentRange == null) return null;
    // bytes 0-12345/12346
    final m = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
    return m != null ? int.parse(m.group(1)!) : null;
  }

  /// 完整文件流式 SHA-256（大文件不整包入内存）。
  static Future<String> sha256OfFile(File file) async {
    final output = _DigestSink();
    final hasher = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      hasher.add(chunk);
    }
    hasher.close();
    return output.value.toString();
  }

  /// 校验并清理：不符返回 false 且删除文件（防继续装被篡改字节）。
  static Future<bool> verifyAndCleanup(File file, String expectedHex) async {
    try {
      final actual = await sha256OfFile(file);
      if (actual.toLowerCase() == expectedHex.toLowerCase()) return true;
      await file.delete().catchError((_) => file);
      return false;
    } on Object {
      await file.delete().catchError((_) => file);
      return false;
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// 下载临时文件名（固定名=天然支持续传复用；路径由调用方给临时目录）。
String updateApkFileName(String version, String assetName) =>
    'zcode-pocket-update-$version-${assetName.hashCode.toRadixString(16)}.apk';

