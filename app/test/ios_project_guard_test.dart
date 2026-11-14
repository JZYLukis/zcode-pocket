// iOS 工程静态守卫（ios-adaptation-2，B 批；android_manifest_guard_test
// 同族先例）：Windows 上无法跑 Xcode 构建，iOS 工程配置的正确性先由
// 静态断言钉死——配置漂移（再跑 flutter create 覆写/手滑改动）在本地
// 测试步即拦，不必等 macOS CI 或云 Mac 才发现。
// 依赖形态=Swift Package Manager（3.47 模板原生：pbxproj 挂
// FlutterGeneratedPluginSwiftPackage 本地包；CI 首跑实证 Podfile 会把
// 插件解析拽回 CocoaPods 混合态→pod install 空跑→sandbox 失配）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String pbxproj;
  late final String infoPlist;
  late final String entitlementsDebug;
  late final String entitlementsRelease;

  setUpAll(() {
    pbxproj = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    entitlementsDebug =
        File('ios/Runner/DebugProfile.entitlements').readAsStringSync();
    entitlementsRelease =
        File('ios/Runner/Release.entitlements').readAsStringSync();
  });

  group('Info.plist（权限与方向）', () {
    test('相机/麦克风权限描述在场且非空（缺描述=权限弹窗被系统直接拒）', () {
      for (final key in [
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
      ]) {
        final m = RegExp(
          '<key>$key</key>\\s*<string>([^<]+)</string>',
        ).firstMatch(infoPlist);
        expect(m, isNotNull, reason: '$key 缺失');
        expect(m!.group(1)!.trim(), isNotEmpty, reason: '$key 描述为空');
      }
    });

    test('竖屏唯一主方向：无横屏条目、无 ~ipad 方向块（iPhone-only）', () {
      expect(
        infoPlist.contains('UIInterfaceOrientationPortrait'),
        isTrue,
        reason: '竖屏条目缺失',
      );
      expect(
        RegExp(r'UIInterfaceOrientationLandscape|PortraitUpsideDown')
            .hasMatch(infoPlist),
        isFalse,
        reason: '存在横屏/倒竖条目——项目硬性要求竖屏唯一',
      );
      expect(
        infoPlist.contains('UISupportedInterfaceOrientations~ipad'),
        isFalse,
        reason: '~ipad 方向块应随 TARGETED_DEVICE_FAMILY=1 移除',
      );
    });

    test('显示名对齐 Android 标签（ZCode Pocket）', () {
      final m = RegExp(
        r'<key>CFBundleDisplayName</key>\s*<string>([^<]+)</string>',
      ).firstMatch(infoPlist);
      expect(m?.group(1), 'ZCode Pocket');
    });
  });

  group('project.pbxproj（身份/设备族/部署目标/entitlements）', () {
    test('Bundle ID 三配置一致（一经设定不再改）', () {
      final ids = RegExp(
        r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);',
      ).allMatches(pbxproj).map((m) => m.group(1)!).toList();
      // 3× Runner（Debug/Profile/Release）+ 3× RunnerTests（后缀）。
      expect(
        ids.where((id) => id == 'dev.zcodeapp.zcodePocket').length,
        3,
        reason: 'Runner 三配置 Bundle ID 必须一致且等于既定值，实际=$ids',
      );
      expect(
        ids.where((id) => id.startsWith('dev.zcodeapp.zcodePocket')).length,
        6,
        reason: 'RunnerTests 三配置应带 .RunnerTests 后缀',
      );
    });

    test('iPhone-only：TARGETED_DEVICE_FAMILY=1 且无 1,2 残留', () {
      expect(
        RegExp(r'TARGETED_DEVICE_FAMILY = 1;').allMatches(pbxproj).length,
        3,
        reason: '三配置必须全部 iPhone-only',
      );
      expect(pbxproj.contains('"1,2"'), isFalse, reason: 'iPhone+iPad 残留');
    });

    test('部署目标 ≥14（file_picker_darwin 下限；当前钉模板档 15.0）', () {
      final targets = RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
      ).allMatches(pbxproj).map((m) => double.parse(m.group(1)!)).toSet();
      expect(targets, isNotEmpty, reason: '解析失败会让本守卫失效');
      for (final t in targets) {
        expect(t >= 14.0, isTrue, reason: '部署目标 $t 低于插件下限 14.0');
      }
    });

    test('Keychain entitlements 接线：Debug/Profile=DebugProfile、Release=Release', () {
      expect(
        RegExp(
          r'CODE_SIGN_ENTITLEMENTS = "Runner/DebugProfile\.entitlements";',
        ).allMatches(pbxproj).length,
        2,
        reason: 'Debug+Profile 两配置须接 DebugProfile.entitlements',
      );
      expect(
        RegExp(
          r'CODE_SIGN_ENTITLEMENTS = "Runner/Release\.entitlements";',
        ).allMatches(pbxproj).length,
        1,
        reason: 'Release 配置须接 Release.entitlements',
      );
      for (final src in [entitlementsDebug, entitlementsRelease]) {
        expect(src.contains('keychain-access-groups'), isTrue);
        expect(
          src.contains('dev.zcodeapp.zcodePocket'),
          isTrue,
          reason: 'keychain 组名须与 Bundle ID 一致',
        );
      }
    });
  });

  group('依赖形态（Swift Package Manager）', () {
    test('SPM 原生接线：FlutterGeneratedPluginSwiftPackage 本地包挂 Runner target', () {
      expect(
        pbxproj.contains(
          'XCLocalSwiftPackageReference "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"',
        ),
        isTrue,
        reason: '3.47 模板 SPM 接线缺失——插件依赖不进工程',
      );
      expect(
        pbxproj.contains('productName = FlutterGeneratedPluginSwiftPackage;'),
        isTrue,
        reason: 'Runner target 缺 SPM 产品依赖',
      );
    });

    test('无 Podfile（在场=形态回退：空 pod install+sandbox 失配，CI 首跑实证）', () {
      expect(
        File('ios/Podfile').existsSync(),
        isFalse,
        reason: '工程为 SPM 原生（pbxproj 挂本地包）——Podfile 会把插件解析'
            '拽回 CocoaPods 混合态，pod install 空跑后 sandbox 与 Manifest '
            '失配必红',
      );
    });

    test('权限宏源=Info.plist（SPM 自动推导）：键集合恰为预期', () {
      // permission_handler_apple SPM 形态从 Info.plist 的 NS*UsageDescription
      // 推导 PERMISSION_* 宏（README §Swift Package Manager）——Info.plist
      // 即权限开关，键多于预期=死权限代码进包（App Store ITMS-90683 风险）。
      final keys = RegExp(
        r'<key>(NS\w*UsageDescription)</key>',
      ).allMatches(infoPlist).map((m) => m.group(1)!).toSet();
      expect(keys, {'NSCameraUsageDescription', 'NSMicrophoneUsageDescription'},
        reason: '新增权限（语音/相册等）须连实现批一起登记本集合，防死权限'
            '代码静默编入',
      );
    });
  });
}
