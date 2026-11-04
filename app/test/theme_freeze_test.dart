// 浅色色值冻结单测（深色模式批 1 第一件事，dark-mode-plan §2 批1-1）。
//
// 目的：theme.dart 全部浅色 token 落快照断言——此后任何浅色值改动即挂，
// 改动须显式解锁（给理由+留痕 ADR）。这是「浅色零回归五道闸」的第 2 道
// （dark-mode-plan §5）。
//
// 维护规则：
// - 预期值=2026-10-23 基线快照（zai-light 镜像 + 4 个可用性主动偏离项，
//   见 theme.dart 头部注释）。除非用户明示解锁，本文件预期值不许改。
// - 深色模式重构后若 token 读取路径变化（static→palette 实例），只允许
//   改「读取处」，预期字面值一律不动。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_pocket/core/theme.dart';

/// Color → AARRGGBB（失败信息可读）。
String hex(Color c) => c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0');

void expectHex(Color actual, int expected, String name) {
  expect(hex(actual), hex(Color(expected)),
      reason: '浅色冻结 token「$name」被改动：'
          '实际 ${hex(actual)} ≠ 基线 ${hex(Color(expected))}。'
          '浅色值一律不动（dark-mode-plan §1-9）；确需改动须用户解锁并留痕。');
}

void main() {
  test('AppColors 浅色全套冻结快照（35 token）', () {
    expectHex(AppThemeSpec.light.colors.background, 0xFFF8F8F8, 'background');
    expectHex(AppThemeSpec.light.colors.header, 0xFFFFFFFF, 'header');
    expectHex(AppThemeSpec.light.colors.sidebar, 0xFFF0F0F0, 'sidebar');
    expectHex(AppThemeSpec.light.colors.card, 0xFFFFFFFF, 'card');
    // Paseo 参考批（2026-10-23）：输入卡专用底——浅色与 card 同值零变化。
    expectHex(AppThemeSpec.light.colors.inputSurface, 0xFFFFFFFF, 'inputSurface=card');
    expectHex(AppThemeSpec.light.colors.surface, 0x080D0D0D, 'surface');
    expectHex(AppThemeSpec.light.colors.surfaceHover, 0x0D0D0D0D, 'surfaceHover');
    expectHex(AppThemeSpec.light.colors.selected, 0x0D0D0D0D, 'selected');
    expectHex(AppThemeSpec.light.colors.border, 0x1A0D0D0D, 'border');
    expectHex(AppThemeSpec.light.colors.borderFaint, 0x140D0D0D, 'borderFaint');
    expectHex(AppThemeSpec.light.colors.borderHover, 0x260D0D0D, 'borderHover');
    expectHex(AppThemeSpec.light.colors.brand, 0xFF000000, 'brand');
    expectHex(AppThemeSpec.light.colors.onBrand, 0xFFFFFFFF, 'onBrand');
    expectHex(AppThemeSpec.light.colors.brandAccent, 0xFF134CFF, 'brandAccent');
    expectHex(AppThemeSpec.light.colors.onBrandAccent, 0xFFFFFFFF, 'onBrandAccent');
    expectHex(AppThemeSpec.light.colors.secondary, 0xFFE6E6E6, 'secondary');
    expectHex(AppThemeSpec.light.colors.accent, 0xFFEBF4FF, 'accent');
    expectHex(AppThemeSpec.light.colors.foreground, 0xFF262626, 'foreground');
    expectHex(AppThemeSpec.light.colors.foregroundSubtle, 0xB3262626, 'foregroundSubtle(70%)');
    expectHex(AppThemeSpec.light.colors.foregroundSubtlest, 0x8C262626, 'foregroundSubtlest(55%)');
    expectHex(AppThemeSpec.light.colors.success, 0xFF15803D, 'success');
    expectHex(AppThemeSpec.light.colors.destructive, 0xFFE03131, 'destructive');
    expectHex(AppThemeSpec.light.colors.warning, 0xFFB45309, 'warning');
    expectHex(AppThemeSpec.light.colors.running, 0xFFB45309, 'running(=warning)');
    expectHex(AppThemeSpec.light.colors.linkBlue, 0xFF0B7FFF, 'linkBlue');
    expectHex(AppThemeSpec.light.colors.idleTask, 0xFF9E77ED, 'idleTask');
    expectHex(AppThemeSpec.light.colors.idleTaskSurface, 0xFFF5F3FF, 'idleTaskSurface');
    expectHex(AppThemeSpec.light.colors.interactionAskSurface, 0xFFEBF4FF, 'interactionAskSurface');
    expectHex(AppThemeSpec.light.colors.interactionAskForeground, 0xFF0066DD, 'interactionAskForeground');
    expectHex(AppThemeSpec.light.colors.interactionConfirmSurface, 0xFFEAF7EE, 'interactionConfirmSurface');
    expectHex(AppThemeSpec.light.colors.interactionConfirmForeground, 0xFF166B32, 'interactionConfirmForeground');
    expectHex(AppThemeSpec.light.colors.diffAdded, 0xFF1E8A3E, 'diffAdded');
    expectHex(AppThemeSpec.light.colors.diffRemoved, 0xFFE03131, 'diffRemoved');
    expectHex(AppThemeSpec.light.colors.shadowXs, 0x080D0D0D, 'shadowXs');
    expectHex(AppThemeSpec.light.colors.shadowMd, 0x14000000, 'shadowMd');
  });

  test('AppChartPalette 浅色冻结快照（series 6 官方 zai + 热力图 5 + 来源 7）', () {
    final series = AppThemeSpec.light.charts.series
        .map(hex)
        .toList();
    expect(series, [
      // 官方 zai-light usage-chart-1..6（2026-10-26 对齐轮重冻结——
      // 原 5 色系 tailwind-600 自选非官方，盘点 audit §六.3 实证）。
      hex(const Color(0xFF0B7FFF)),
      hex(const Color(0xFF1E8A3E)),
      hex(const Color(0xFF9E77ED)),
      hex(const Color(0xFFE03131)),
      hex(const Color(0xFFE07B00)),
      hex(const Color(0xFF0AA7A7)),
    ], reason: '图表 series 6 色=官方 zai-light 冻结');

    final heatmap = AppThemeSpec.light.charts.heatmapGreens.map(hex).toList();
    expect(heatmap, [
      hex(const Color(0xFFEBEDF0)),
      hex(const Color(0xFFC6E9C4)),
      hex(const Color(0xFF8CD98A)),
      hex(const Color(0xFF4CAF50)),
      hex(const Color(0xFF217A2B)),
    ], reason: '热力图绿阶 5 级冻结（浅色=绿阶语义；官方浅色实为蓝阶的已知'
        '偏差见 dark-mode-plan §3）');

    final sources = AppThemeSpec.light.charts.sourceColors.map(hex).toList();
    expect(sources, [
      hex(const Color(0xFF2563EB)),
      hex(const Color(0xFF16A34A)),
      hex(const Color(0xFFEA580C)),
      hex(const Color(0xFF9333EA)),
      hex(const Color(0xFF0891B2)),
      hex(const Color(0xFF64748B)),
      hex(const Color(0xFFDB2777)),
    ], reason: '来源圆点 7 色冻结');
  });

  test('AppShadow 档位几何冻结（颜色+blur+offset）', () {
    final xs = AppThemeSpec.light.shadows.xs.single;
    expect(hex(xs.color), hex(const Color(0x080D0D0D)));
    expect(xs.blurRadius, 6);
    expect(xs.offset, const Offset(0, 2));

    final md = AppThemeSpec.light.shadows.md.single;
    expect(hex(md.color), hex(const Color(0x14000000)));
    expect(md.blurRadius, 12);
    expect(md.offset, const Offset(0, 4));
  });

  test('浅色终端/git 色板冻结（批1 新增数据层，接线消费前上闸——路A2 B-1）', () {
    final t = AppThemeSpec.light.terminal;
    expectHex(t.bg, 0xFFF8F8F8, 'terminal.bg');
    expectHex(t.fg, 0xFF262626, 'terminal.fg');
    expectHex(t.cursor, 0xFF0D0D0D, 'cursor');
    expectHex(t.cursorAccent, 0xFFF8F8F8, 'cursorAccent');
    expectHex(t.selection, 0x380B7FFF, 'selection');
    expectHex(t.selectionInactive, 0x1A0D0D0D, 'selectionInactive');
    expectHex(t.black, 0xFF5C5C5C, 'black');
    expectHex(t.red, 0xFFE03131, 'red');
    expectHex(t.green, 0xFF1E8A3E, 'green');
    expectHex(t.yellow, 0xFFE07B00, 'yellow');
    expectHex(t.blue, 0xFF0B7FFF, 'blue');
    expectHex(t.magenta, 0xFF9E77ED, 'magenta');
    expectHex(t.cyan, 0xFF0AA7A7, 'cyan');
    expectHex(t.white, 0xFFADADAD, 'white');
    expectHex(t.brightBlack, 0xFF888888, 'brightBlack');
    expectHex(t.brightBlue, 0xFF0066DD, 'brightBlue');
    expectHex(t.brightWhite, 0xFF0D0D0D, 'brightWhite');
    final g = AppThemeSpec.light.git;
    expectHex(g.none, 0xFF262626, 'git.none');
    expectHex(g.modified, 0xFFE07B00, 'git.modified');
    expectHex(g.added, 0xFF1E8A3E, 'git.added');
    expectHex(g.deleted, 0xFFE03131, 'git.deleted');
    expectHex(g.renamed, 0xFF0B7FFF, 'git.renamed');
    expectHex(g.untracked, 0xFF1E8A3E, 'git.untracked');
    expectHex(g.ignored, 0x8C262626, 'git.ignored(=subtlest 55%)');
    expectHex(g.descendant, 0xFFE07B00, 'git.descendant');
  });

  test('buildAppTheme() 浅色 ThemeData 关键输出冻结', () {
    final t = buildAppTheme();
    expectHex(t.scaffoldBackgroundColor, 0xFFF8F8F8, 'scaffoldBackgroundColor');
    expectHex(t.colorScheme.primary, 0xFF000000, 'colorScheme.primary');
    expectHex(t.colorScheme.onPrimary, 0xFFFFFFFF, 'colorScheme.onPrimary');
    expectHex(t.colorScheme.secondary, 0xFFE6E6E6, 'colorScheme.secondary');
    expectHex(t.colorScheme.surface, 0xFFFFFFFF, 'colorScheme.surface');
    expectHex(t.colorScheme.error, 0xFFE03131, 'colorScheme.error');
    expectHex(t.appBarTheme.backgroundColor!, 0xFFFFFFFF, 'appBar.background');
    expectHex(t.appBarTheme.foregroundColor!, 0xFF262626, 'appBar.foreground');
    expectHex(t.cardTheme.color!, 0xFFFFFFFF, 'card.color');
    expectHex(
        (t.cardTheme.shape as RoundedRectangleBorder).side.color,
        0x140D0D0D,
        'card.shape.borderFaint');
    expectHex(t.dividerTheme.color!, 0x1A0D0D0D, 'divider.color');
    expect(t.dividerTheme.thickness, 1);
    expectHex(
        t.filledButtonTheme.style!.backgroundColor!.resolve({})!,
        0xFF000000,
        'filledButton.background');
    expectHex(
        t.filledButtonTheme.style!.foregroundColor!.resolve({})!,
        0xFFFFFFFF,
        'filledButton.foreground');
    expectHex(t.floatingActionButtonTheme.backgroundColor!,
        0xFF134CFF, 'fab.background(brandAccent)');
    expectHex(t.floatingActionButtonTheme.foregroundColor!,
        0xFFFFFFFF, 'fab.foreground');
  });
}
