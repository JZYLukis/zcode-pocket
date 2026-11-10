/// Parses a ZCode web-remote connection URL, e.g.
/// https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...&app_version=...
///
/// Mirrors `zC()` in the web client bundle.
class CompanionConnectionParams {
  final String deviceSid;
  final String passHash;
  final int timestamp;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;
  final String? theme;
  final Uri source;

  const CompanionConnectionParams({
    required this.deviceSid,
    required this.passHash,
    required this.timestamp,
    required this.source,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
    this.theme,
  });

  static String? _get(Uri uri, String key) {
    final v = uri.queryParameters[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static CompanionConnectionParams? parse(String raw) {
    // 全程 try（P2-4/F3-P2-2/M3-P1-1 三路同报）：Uri.parse
    // 宽容接受畸形百分号转义，异常延迟到 queryParameters 惰性解码才抛
    // ——此前 try 只包 Uri.parse，粘贴框每键击的 _syncName/连接按钮会
    // 收到未捕获异常。契约=无效一律返回 null。
    try {
      final uri = Uri.parse(raw.trim());
      final sid = _get(uri, 'sid');
      final hash = _get(uri, 'hash');
      final t = int.tryParse(_get(uri, 't') ?? '');
      if ((uri.scheme != 'https' && uri.scheme != 'wss') ||
          sid == null ||
          hash == null ||
          t == null) {
        return null;
      }
      return CompanionConnectionParams(
        deviceSid: sid,
        passHash: hash,
        timestamp: t,
        deviceMid: _get(uri, 'mid'),
        deviceName: _get(uri, 'name'),
        appVersion: _get(uri, 'app_version'),
        theme: _get(uri, 'theme'),
        source: uri,
      );
    } catch (_) {
      return null;
    }
  }

  /// 官方中继域名（V1/V2 唯一受信 origin；V2 路由谓词
  /// [isV2PairingUrl] 与配对页确认共用）。
  static const officialHost = 'zcode.z.ai';

  /// 链接主机是否官方中继（V1 解析不限制 host——任意 https/wss 都
  /// 合法，配对 UI 对非官方域必须显式确认，防恶意二维码把连接引向
  /// 自建服务器）。
  bool get isOfficialHost => source.host.toLowerCase() == officialHost;

  /// Relay websocket URL. Mirrors `Jc()` / `pen.connect()`:
  /// `wss://<host>/ws` plus `?mid=` when present.
  ///
  /// P3-10：旧实现为非安全 scheme 准备了 `ws://` 分支——
  /// 但 [parse] 硬性要求 https/wss（生产唯一构造路径），该分支永不可达，
  /// 属自相矛盾的死代码，已删（早期实现，已移除）。
  Uri get relayWsUri {
    final base = Uri(
      scheme: 'wss',
      host: source.host,
      port: source.hasPort ? source.port : null,
      path: '/ws',
    );
    if (deviceMid == null) return base;
    return base.replace(queryParameters: {'mid': deviceMid});
  }
}

/// V2 二维码/深链参数。官方 3.16 起 URL 只带路由提示
/// （sid/mid/name/app_version），凭据核心=账号登录；V1 的 hash/t 被清除。
///
/// 解析语义对齐官方 parseWebRemoteControlExternalQrParams
/// （refs web-remote-control.ts:191-206）：**带 hash 或 t（哪怕空值）的
/// V1 链接返回 null——不存在 V1 解析回退**；全空参数合法（=账号登录后
/// 走设备列表选电脑）。
class CompanionV2Params {
  final String? deviceSid;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;
  final Uri? source;

  const CompanionV2Params({
    this.deviceSid,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
    this.source,
  });
}

CompanionV2Params? parseCompanionV2Params(String raw) {
  // 同 CompanionConnectionParams.parse：queryParameters 惰性解码对畸形
  // 百分号转义抛异常——全程 try，无效一律 null（三路同报）。
  try {
    final uri = Uri.parse(raw.trim());
    if ((uri.scheme != 'https' && uri.scheme != 'wss') ||
        uri.host.isEmpty) {
      return null;
    }
    final q = uri.queryParameters;
    if (q.containsKey('hash') || q.containsKey('t')) return null;
    String? nonZero(String? v) {
      final t = v?.trim() ?? '';
      return t.isEmpty ? null : t;
    }

    return CompanionV2Params(
      deviceSid: nonZero(q['sid']),
      deviceMid: nonZero(q['mid']),
      deviceName: nonZero(q['name']),
      appVersion: nonZero(q['app_version']),
      source: uri,
    );
  } catch (_) {
    return null;
  }
}

/// PairingPage 路由谓词：粘贴框里的链接走 V2 账号流程的条件——官方
/// origin 且**至少带 sid/mid/name/app_version 之一**（全空参数虽然解析
/// 合法=设备列表流程，但那由"账号登录"专用入口触发；粘贴框里的无参
/// URL 一律按无效处理，与 V1 档案行为一致）。
bool isV2PairingUrl(String raw) {
  final p = parseCompanionV2Params(raw);
  if (p == null) return false;
  if (p.source?.host != 'zcode.z.ai') return false;
  return p.deviceSid != null ||
      p.deviceMid != null ||
      p.deviceName != null ||
      p.appVersion != null;
}
