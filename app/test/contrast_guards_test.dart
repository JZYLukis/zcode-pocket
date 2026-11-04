// 深色模式批2-6：守卫自动化。
// ①结构成对断言（design_scan R6 的架构等效落地）：批1 架构=单类双实例
//   （AppColors 等五类共用构造器，浅/深两实例字段集编译期强制同构），
//   R6 原语义"token 缺深色对应即挂"由编译器天然保证；此处补运行期
//   可查的部分：两套图表列表长度一致（索引取色安全）+扩展挂载完备。
// ②对比度红线单测（ADR 0035 决策⑦）：正文 4.5:1/图标·大字·交互边界
//   3:1，浅深两套全算；官方/等效果偏低组合按底账"记录在案放行留档"
//   （Exemptions 表，任何新漂移仍会挂）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_pocket/core/theme.dart';

/// WCAG 相对亮度对比度。
double ratio(Color a, Color b) {
  double lum(Color c) {
    // 从 toARGB32 位通道取值（Color.r 等访问器跨版本语义漂移，位取稳）。
    final argb = c.toARGB32();
    double ch(int v) {
      final s = v / 255.0;
      return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * ch((argb >> 16) & 0xFF) +
        0.7152 * ch((argb >> 8) & 0xFF) +
        0.0722 * ch(argb & 0xFF);
  }

  final l1 = lum(a), l2 = lum(b);
  final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

/// 半透明色先合成到底色（alpha 通道位取，跨版本稳）。
Color composite(Color over, Color bg) {
  final a = ((over.toARGB32() >> 24) & 0xFF) / 255.0;
  return Color.lerp(bg, over, a)!;
}

void check(String name, Color fg, Color bg, double min, String note) {
  // 透明前景先合成到底色（不透明色合成=自身，幂等安全）。
  final r = ratio(composite(fg, bg), bg);
  expect(r >= min, isTrue,
      reason: '「$name」对比度 ${r.toStringAsFixed(2)}:1 低于红线 $min:1'
          '（$note）。修正值或调整 Exemptions 须留痕 ADR。');
}

void main() {
  group('R6 结构成对断言（架构等效落地）', () {
    test('图表列表两套等长（索引取色安全）', () {
      final l = AppThemeSpec.light.charts, d = AppThemeSpec.dark.charts;
      expect(l.series.length, d.series.length);
      expect(l.heatmapGreens.length, d.heatmapGreens.length);
      expect(l.sourceColors.length, d.sourceColors.length);
      expect(l.series.length, 6);
      expect(l.sourceColors.length, 7);
    });

    test('两套 ThemeData 均挂载扩展（buildAppTheme 唯一构造点语义）', () {
      expect(buildAppTheme().extension<AppThemeSpec>(), isNotNull);
      expect(buildAppTheme(Brightness.dark).extension<AppThemeSpec>(), isNotNull);
    });
  });

  group('对比度红线（正文 4.5 / 图标大字交互边界 3；两套全算）', () {
    final suites = {
      '浅色': AppThemeSpec.light.colors,
      '深色': AppThemeSpec.dark.colors,
    };
    for (final e in suites.entries) {
      final name = e.key, c = e.value;
      test('$name 正文族（foreground 系 vs 背景/卡片）', () {
        check('foreground/background', c.foreground, c.background, 4.5, '正文红线');
        check('foreground/card', c.foreground, c.card, 4.5, '卡片上正文');
        check('foreground/header', c.foreground, c.header, 4.5, '顶栏文字');
        check('foreground/inputSurface', c.foreground, c.inputSurface, 4.5,
            '输入卡上正文（A7② 2026-10-24 补：Paseo 批新增面此前无守卫条目）');
        check('foregroundSubtle/background', c.foregroundSubtle, c.background,
            4.5, '次要文字');
        // foregroundSubtle/card：浅 5.57 / 深 4.49（官方 60% 值+临界，
        // Exemptions：记录在案放行——官方 zai-dark subtle 即此档）。
      });
      test('$name 状态色（图标/圆点 3:1 vs 背景/卡片）', () {
        for (final entry in {
          'success': c.success,
          'warning': c.warning,
          'destructive': c.destructive,
          'running': c.running,
          'linkBlue': c.linkBlue,
          'idleTask': c.idleTask,
          'brandAccent': c.brandAccent,
        }.entries) {
          check('${entry.key}/background', entry.value, c.background, 3.0,
              '状态图标/点睛位非文本线');
          check('${entry.key}/card', entry.value, c.card, 3.0, '卡片上状态图标');
        }
      });
      test('$name 按钮文字（实底前景 vs 实底）', () {
        check('onBrand/brand', c.onBrand, c.brand, 4.5, '主按钮文字');
        check('onBrandAccent/brandAccent', c.onBrandAccent, c.brandAccent, 3.0,
            'FAB/点睛实底图标（批1-5 校准定稿档）');
      });
    }

    test('终端前景 4.5（数据层）', () {
      for (final spec in [AppThemeSpec.light, AppThemeSpec.dark]) {
        check('terminal.fg/bg[${spec == AppThemeSpec.light ? "浅" : "深"}]',
            spec.terminal.fg, spec.terminal.bg, 4.5, '终端正文');
      }
    });

    test('Exemptions（记录在案放行留档——任何漂移仍会挂；透明色先合成）',
        () {
      final l = AppThemeSpec.light.colors, d = AppThemeSpec.dark.colors;
      // 深 subtlest 47%：等效果档（浅色同位 55%=3.64 亦未过正文线——
      // 辅助文字档，官方/浅色历史同型偏离，A3/B1 审查记录在案）。
      expect(ratio(composite(d.foregroundSubtlest, d.background), d.background),
          allOf(greaterThan(3.0), lessThan(4.5)),
          reason: '深 subtlest 应处 3-4.5 辅助档；越界=校准漂移');
      expect(ratio(composite(l.foregroundSubtlest, l.background), l.background),
          allOf(greaterThan(3.0), lessThan(4.5)),
          reason: '浅 subtlest 同为辅助档（浅色侧冻结不动）');
      // 深 foregroundSubtle/card 4.49 临界（官方 60% 值起步，批2 复核记录）。
      expect(
          ratio(composite(d.foregroundSubtle, d.card), d.card),
          greaterThan(4.4),
          reason: '深 subtle on card 官方档临界带 4.4-4.5，跌破=漂移');
      // 浅错误横幅红字 on 8% 粉底 3.79（A3 B1：基线既有，待用户解锁修正）。
      final pink = Color.lerp(l.background, l.destructive, 0.08)!;
      expect(ratio(l.destructive, pink), greaterThan(3.5),
          reason: '浅错误横幅红字（记录在案 3.79，跌破 3.5=恶化）');
    });
  });
}
