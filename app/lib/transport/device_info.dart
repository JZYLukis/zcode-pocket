import 'package:flutter/foundation.dart';

/// Device identity sent during relay auth and mobile-view-state updates.
///
/// The web client reports itself as a browser; this app identifies itself
/// honestly so the desktop can show the real connected client. 开源审查
/// F2-P3-7：项目已更名 ZCode Pocket（ADR 0015），旧标识失真——官方桌面
/// 端对该串只做展示（refs webRemoteControlDeviceGroups.ts，无白名单
/// 匹配），随开源批一并更名。
const companionAppName = 'zcode-pocket';

/// Real runtime platform (android / web / windows / ...), defaults to `web`
/// when unknown so the handshake stays valid on exotic targets.
String companionPlatformName() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return 'fuchsia';
  }
}
