// 厂商档位规范化与引导文案选择。
// 华为档文案逐字钉死（既有用户零回归）；vivo 档旅程单独锁。
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/oem_vendor.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/notify_guide_page.dart';

void main() {
  group('oemVendorFromManufacturer 规范化', () {
    test('真机常见上报形态', () {
      expect(oemVendorFromManufacturer('HUAWEI'), OemVendor.huawei);
      expect(oemVendorFromManufacturer('HONOR'), OemVendor.honor);
      expect(oemVendorFromManufacturer('vivo'), OemVendor.vivo);
      expect(oemVendorFromManufacturer('iQOO'), OemVendor.vivo);
      expect(oemVendorFromManufacturer('Xiaomi'), OemVendor.xiaomi);
      expect(oemVendorFromManufacturer('Redmi'), OemVendor.xiaomi);
      expect(oemVendorFromManufacturer('OPPO'), OemVendor.oppo);
      expect(oemVendorFromManufacturer('OnePlus'), OemVendor.oppo);
      expect(oemVendorFromManufacturer('realme'), OemVendor.oppo);
    });

    test('未知/空/异常串落通用档', () {
      expect(oemVendorFromManufacturer('samsung'), OemVendor.other);
      expect(oemVendorFromManufacturer('Google'), OemVendor.other);
      expect(oemVendorFromManufacturer(''), OemVendor.other);
      expect(oemVendorFromManufacturer('  '), OemVendor.other);
    });

    test('大小写与混合形态（lowercase 包含匹配）', () {
      expect(oemVendorFromManufacturer('Huawei'), OemVendor.huawei);
      expect(oemVendorFromManufacturer('VIVO'), OemVendor.vivo);
      expect(oemVendorFromManufacturer('Xiaomi Communications'), OemVendor.xiaomi);
    });
  });

  group('oemStartupGuideFor 文案档', () {
    test('华为档=阶段 3 原版文案逐字一致（零回归钉死）', () {
      final g = oemStartupGuideFor(OemVendor.huawei);
      expect(g.title, '启动管理三开关');
      expect(
        g.body,
        '设置 → 应用 → 应用启动管理 → ZCode Pocket → 改为"手动管理"，'
        '开启 自启动 / 关联启动 / 后台活动 三个开关。',
      );
      expect(
        g.startupNote,
        '已跳到「启动管理」：找到 ZCode Pocket 改为手动管理，'
        '开启自启动/关联启动/后台活动三个开关',
      );
    });

    test('六档文案齐备且 body 互异（同 title 允许，路径必须不同）', () {
      final guides = {
        for (final v in OemVendor.values) v: oemStartupGuideFor(v),
      };
      for (final e in guides.entries) {
        expect(e.value.title, isNotEmpty, reason: '${e.key} title 空');
        expect(e.value.body, isNotEmpty, reason: '${e.key} body 空');
        expect(e.value.startupNote, isNotEmpty, reason: '${e.key} note 空');
        expect(e.value.detailsNote, isNotEmpty, reason: '${e.key} details 空');
      }
      final bodies = guides.values.map((g) => g.body).toSet();
      expect(bodies.length, guides.length, reason: '存在两档 body 相同');
    });

    test('vivo 档引导走电池侧路径（OriginOS 后台清理不在应用详情页）', () {
      final g = oemStartupGuideFor(OemVendor.vivo);
      expect(g.body, contains('后台耗电管理'));
      expect(g.body, contains('自启动'));
    });
  });

  group('NotifyGuidePage 档位渲染', () {
    Future<void> _pump(
      WidgetTester tester,
      NotifyGuidePage page,
    ) async {
      await tester.pumpWidget(
        MaterialApp(theme: buildAppTheme(), home: page),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('vivo 档：第 1 步展示 OriginOS 路径文案', (tester) async {
      await _pump(
        tester,
        const NotifyGuidePage(vendorOverrideForTest: OemVendor.vivo),
      );
      expect(find.text('自启动与后台运行'), findsOneWidget);
      expect(find.textContaining('后台耗电管理'), findsOneWidget);
      // 华为专属术语不再出现在 vivo 档。
      expect(find.text('启动管理三开关'), findsNothing);
      expect(find.textContaining('关联启动'), findsNothing);
    });

    testWidgets('未知厂商档：通用文案，无品牌专属路径', (tester) async {
      await _pump(
        tester,
        const NotifyGuidePage(vendorOverrideForTest: OemVendor.other),
      );
      expect(find.textContaining('不同品牌的入口名称与路径不同'), findsOneWidget);
    });

    testWidgets('通道读取失败回落华为档（测试环境无 handler=现网极端路径）',
        (tester) async {
      await _pump(tester, const NotifyGuidePage());
      // 未注入 override：MethodChannel 抛 MissingPluginException → 华为档。
      expect(find.text('启动管理三开关'), findsOneWidget);
      expect(
        find.textContaining('开启 自启动 / 关联启动 / 后台活动 三个开关'),
        findsOneWidget,
      );
    });
  });
}
