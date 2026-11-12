// 应用内更新——检查与元数据。
//
// 数据源：GitHub `releases/latest`（一次返回 tag+各 APK 资产 URL+官方
// sha256 digest——v1.0.4 实测 digest 与 SHA256SUMS 逐字节吻合，作为
// 下载校验的信任锚）。直连 api.github.com；失败静默（检查是增强不是
// 关键路径）。不引 http/dio：dart:io HttpClient 走 voice_refine.dart
// 的超时分层先例。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const _kRepo = 'JZYLukis/zcode-pocket';

/// 测试缝：本机 HttpServer 覆盖 API 基址（relay_v2_test 同款先例）。
@visibleForTesting
String? debugUpdateApiBaseOverride;

class UpdateAsset {
  final String name;
  final String url;
  final String sha256Hex; // 官方 digest（去 sha256: 前缀）
  const UpdateAsset(this.name, this.url, this.sha256Hex);
}

class UpdateInfo {
  final String version; // '1.0.5'（去 v 前缀）
  final String notes; // 朴素文本 changelog
  final List<UpdateAsset> assets;
  const UpdateInfo(this.version, this.notes, this.assets);

  UpdateAsset? assetForAbi(String abi) => pickAssetForAbi(assets, abi);
}

/// 版本比较：versionName 形如 `1.0.4-<12位SHA>`（build-release 出包），
/// 取 `-` 前 SemVer 与 tag（v 前缀可选）比较。返回 true=远端更新。
bool isNewerVersion(String remoteTag, String currentVersionName) {
  final remote = semverOf(remoteTag);
  final current = semverOf(currentVersionName);
  if (remote == null || current == null) return false;
  final cmp = compareSemver(remote, current);
  return cmp > 0;
}

/// `v1.0.5` / `1.0.5-abc123` → [1,0,5]；不合法返回 null。
List<int>? semverOf(String raw) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final dash = s.indexOf('-');
  if (dash >= 0) s = s.substring(0, dash);
  final parts = s.split('.');
  if (parts.length != 3) return null;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0) return null;
    nums.add(n);
  }
  return nums;
}

int compareSemver(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return 0;
}

/// ABI → 资产匹配（资产名后缀 zcode-pocket-<版本>-<abi>.apk）。
UpdateAsset? pickAssetForAbi(List<UpdateAsset> assets, String abi) {
  // SUPPORTED_ABIS[0] 可能返回 arm64-v8a/armeabi-v7a/x86_64 等；做一次
  // 常见别名归一（arm64→arm64-v8a）。
  final normalized = switch (abi) {
    'arm64' => 'arm64-v8a',
    'arm32' || 'armeabi' => 'armeabi-v7a',
    'x86' || 'x64' => 'x86_64',
    _ => abi,
  };
  for (final a in assets) {
    if (a.name.endsWith('-$normalized.apk')) return a;
  }
  return null;
}

/// `sha256:abcd…` → `abcd…`；无前缀且形如 64 位十六进制也接受。
String? parseDigest(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.startsWith('sha256:')) s = s.substring(7);
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(s) ? s : null;
}

/// Release body（markdown）→ 朴素文本：去标题井号/链接语法/表格竖线，
/// 折叠连续空行。仅用于弹窗展示，不做完整 md 渲染。
String stripMarkdownNotes(String body) {
  final out = StringBuffer();
  var blankRun = false;
  for (final rawLine in const LineSplitter().convert(body)) {
    var line = rawLine
        .replaceAll(RegExp(r'^#{1,6}\s*'), '')
        .replaceAllMapped(
            RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAll(RegExp(r'^\|.*\|$'), '')
        .replaceAll(RegExp(r'^[-*]\s+'), '· ')
        .replaceAll('> ', '')
        .trimRight();
    if (line.trim().isEmpty) {
      if (!blankRun && out.isNotEmpty) out.writeln();
      blankRun = true;
      continue;
    }
    blankRun = false;
    out.writeln(line);
  }
  return out.toString().trim();
}

class UpdateCheckException implements Exception {
  final String reason;
  const UpdateCheckException(this.reason);
  @override
  String toString() => 'UpdateCheckException($reason)';
}

/// 拉取 latest release 元数据。抛 [UpdateCheckException]（调用方静默/
/// 提示自定）。
Future<UpdateInfo> fetchLatestRelease() async {
  final base = debugUpdateApiBaseOverride ?? 'https://api.github.com';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client
        .getUrl(Uri.parse('$base/repos/$_kRepo/releases/latest'))
        .timeout(const Duration(seconds: 10));
    // 未认证 GitHub API 要求 User-Agent。
    req.headers.set('User-Agent', 'zcode-pocket-updater');
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 12));
    if (res.statusCode == 403 || res.statusCode == 429) {
      throw const UpdateCheckException('rate-limited');
    }
    if (res.statusCode != 200) {
      throw UpdateCheckException('http-${res.statusCode}');
    }
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    return parseReleaseJson(body);
  } on UpdateCheckException {
    rethrow;
  } on Object {
    throw const UpdateCheckException('network');
  } finally {
    client.close(force: true);
  }
}

/// JSON 解析（纯函数，可测）。
UpdateInfo parseReleaseJson(String body) {
  final Map<dynamic, dynamic> json;
  try {
    json = jsonDecode(body) as Map<dynamic, dynamic>;
  } on Object {
    throw const UpdateCheckException('bad-json');
  }
  final tagName = json['tag_name'];
  if (tagName is! String) throw const UpdateCheckException('no-tag');
  final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
  final assetsRaw = json['assets'];
  final assets = <UpdateAsset>[];
  if (assetsRaw is List) {
    for (final a in assetsRaw) {
      if (a is! Map) continue;
      final name = a['name'];
      final url = a['browser_download_url'];
      if (name is! String || url is! String) continue;
      final digest = parseDigest(a['digest'] as String?);
      if (digest == null) continue; // 无官方哈希的资产不参与应用内更新
      assets.add(UpdateAsset(name, url, digest));
    }
  }
  final notesBody = json['body'];
  return UpdateInfo(
    version,
    stripMarkdownNotes(notesBody is String ? notesBody : ''),
    assets,
  );
}
