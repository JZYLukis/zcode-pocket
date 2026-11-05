// 深色色板快照单测（深色模式批 1，dark-mode-plan §3 底账为判卷标准）。
//
// 目的：钉住官方 zai-dark 1:1 搬运值——任何深色值笔误/漂移即挂；批 1
// 横向校准（智谱蓝/热力图/阴影裁量）调整值时须同步改本文件并留痕
// 补记（与浅色冻结不同：深色值允许按校准结论调整，但必须显式）。
// 来源：refs/ZCode/packages/ui/src/styles.css:638-783（已核 3.16.1 零变化）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_pocket/core/theme.dart';

String hex(Color c) =>
    c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0');

void expectHex(Color actual, int expected, String name) {
  expect(hex(actual), hex(Color(expected)),
      reason: '深色 token「$name」漂移：实际 ${hex(actual)} ≠ 底账 '
          '${hex(Color(expected))}（dark-mode-plan §3；校准改值须留痕）');
}

void main() {
  test('AppColors 深色全套快照（官方 zai-dark）', () {
    final c = AppThemeSpec.dark.colors;
    expectHex(c.background, 0xFF161616, 'background');
    expectHex(c.header, 0xFF202020, 'header');
    expectHex(c.sidebar, 0xFF161616, 'sidebar');
    expectHex(c.card, 0xFF2B2B2B, 'card');
 // Paseo 参考批（2026-10-23 用户拍板）：输入卡深色降一档（不连坐
 // popover/menu/toast）。
    expectHex(c.inputSurface, 0xFF232322, 'inputSurface');
    expectHex(c.surface, 0x0DFFFFFF, 'surface(白5%)');
    expectHex(c.surfaceHover, 0x1AFFFFFF, 'surfaceHover(白10%)');
    expectHex(c.selected, 0x1AFFFFFF, 'selected(白10%)');
    expectHex(c.border, 0x1AFFFFFF, 'border(白10%)');
    expectHex(c.borderFaint, 0x14FFFFFF, 'borderFaint(白8%)');
    expectHex(c.borderHover, 0x26FFFFFF, 'borderHover(白15%)');
    expectHex(c.brand, 0xFFFFFFFF, 'brand(黑白反转)');
    expectHex(c.onBrand, 0xFF000000, 'onBrand');
    expectHex(c.brandAccent, 0xFF4099FF, 'brandAccent(#4099FF 基准)');
    expectHex(c.onBrandAccent, 0xFF001D3D, 'onBrandAccent(深蓝前景 校准)');
    expectHex(c.secondary, 0xFF363636, 'secondary');
    expectHex(c.accent, 0xFF001D3D, 'accent');
    expectHex(c.foreground, 0xFFD4D4D4, 'foreground(neutral-300)');
 // ⚠ 官方值起步（60%/30%）；批 2 对比度单测不过线则提亮并改此处留痕。
    expectHex(c.foregroundSubtle, 0x99D4D4D4, 'foregroundSubtle(60%)');
    expectHex(c.foregroundSubtlest, 0x5CD4D4D4, 'foregroundSubtlest(36% 等效果随浅色回撤)');
    expectHex(c.success, 0xFF46BF72, 'success');
    expectHex(c.destructive, 0xFFFF5C5C, 'destructive');
    expectHex(c.warning, 0xFFFF8A30, 'warning');
    expectHex(c.running, 0xFFFF8A30, 'running(=warning)');
    expectHex(c.linkBlue, 0xFF4099FF, 'linkBlue');
    expectHex(c.idleTask, 0xFF7B5CE5, 'idleTask');
    expectHex(c.idleTaskSurface, 0xFF160D38, 'idleTaskSurface');
    expectHex(c.interactionAskSurface, 0xFF001D3D, 'interactionAskSurface');
    expectHex(c.interactionAskForeground, 0xFF80BEEF, 'interactionAskForeground');
    expectHex(c.interactionConfirmSurface, 0x2946BF72, 'interactionConfirmSurface(16%)');
    expectHex(c.interactionConfirmForeground, 0xFF87D9A4, 'interactionConfirmForeground');
    expectHex(c.diffAdded, 0xFF46BF72, 'diffAdded');
    expectHex(c.diffRemoved, 0xFFFF5C5C, 'diffRemoved');
 // 裁量档。
    expectHex(c.shadowXs, 0x59000000, 'shadowXs(黑35% 裁量)');
    expectHex(c.shadowMd, 0x80000000, 'shadowMd(黑50% 裁量)');
  });

  test('终端 16 色+光标+选区深色快照（官方 terminal-*）', () {
    final t = AppThemeSpec.dark.terminal;
    expectHex(t.bg, 0xFF161616, 'terminal.bg');
    expectHex(t.fg, 0xFFD4D4D4, 'terminal.fg');
    expectHex(t.cursor, 0xFFF8F8F8, 'cursor');
    expectHex(t.cursorAccent, 0xFF161616, 'cursorAccent');
    expectHex(t.selection, 0x474099FF, 'selection(0.28)');
    expectHex(t.selectionInactive, 0x1AFFFFFF, 'selectionInactive');
    expectHex(t.black, 0xFF363636, 'black');
    expectHex(t.red, 0xFFFF5C5C, 'red');
    expectHex(t.green, 0xFF46BF72, 'green');
    expectHex(t.yellow, 0xFFFF8A30, 'yellow');
    expectHex(t.blue, 0xFF4099FF, 'blue');
    expectHex(t.magenta, 0xFF7B5CE5, 'magenta');
    expectHex(t.cyan, 0xFF42C8C8, 'cyan');
    expectHex(t.white, 0xFFADADAD, 'white');
    expectHex(t.brightBlack, 0xFF747474, 'brightBlack');
    expectHex(t.brightRed, 0xFFFF9999, 'brightRed');
    expectHex(t.brightGreen, 0xFF87D9A4, 'brightGreen');
    expectHex(t.brightYellow, 0xFFFFB26B, 'brightYellow');
    expectHex(t.brightBlue, 0xFF80BEFF, 'brightBlue');
    expectHex(t.brightMagenta, 0xFFA888F2, 'brightMagenta');
    expectHex(t.brightCyan, 0xFF8EE5E5, 'brightCyan');
    expectHex(t.brightWhite, 0xFFF8F8F8, 'brightWhite');
  });

  test('git 状态色深色快照（官方 git-*）', () {
    final g = AppThemeSpec.dark.git;
    expectHex(g.none, 0xFFD4D4D4, 'none');
    expectHex(g.modified, 0xFFFF8A30, 'modified');
    expectHex(g.added, 0xFF46BF72, 'added');
    expectHex(g.deleted, 0xFFFF5C5C, 'deleted');
    expectHex(g.renamed, 0xFF4099FF, 'renamed');
    expectHex(g.untracked, 0xFF46BF72, 'untracked');
    expectHex(g.ignored, 0x4DD4D4D4, 'ignored(官方渲染值 30% 不随 subtlest 校准联动)');
    expectHex(g.descendant, 0xFFFF8A30, 'descendant');
  });

  test('图表深色快照（官方 usage-chart 前5 + 裁量项）', () {
    final ch = AppThemeSpec.dark.charts;
    expect(ch.series.map(hex).toList(), [
      hex(const Color(0xFF4099FF)),
      hex(const Color(0xFF46BF72)),
      hex(const Color(0xFF7B5CE5)),
      hex(const Color(0xFFFF5C5C)),
      hex(const Color(0xFFFF8A30)),
 // 2026-10-26 对齐轮：补官方第 6 色（原 5 色循环少一档）。
      hex(const Color(0xFF42C8C8)),
    ], reason: 'series=官方 usage-chart 深色 6 色');
 // 裁量：绿阶深色版。
    expect(ch.heatmapGreens.map(hex).toList(), [
      hex(const Color(0xFF252B28)),
      hex(const Color(0xFF1B4531)),
      hex(const Color(0xFF247A4B)),
      hex(const Color(0xFF46BF72)),
      hex(const Color(0xFF6FD98A)),
    ], reason: '热力图绿阶深色版（批1-5 校准：顶档提亮 GitHub 同构）');
 // 裁量：来源 7 色提亮版。
    expect(ch.sourceColors.map(hex).toList(), [
      hex(const Color(0xFF4099FF)),
      hex(const Color(0xFF46BF72)),
      hex(const Color(0xFFFF8A30)),
      hex(const Color(0xFF7B5CE5)),
      hex(const Color(0xFF42C8C8)),
      hex(const Color(0xFFADADAD)),
      hex(const Color(0xFFF472B6)),
    ], reason: '来源圆点提亮版（裁量）');
  });

  test('阴影档位深色快照+单源一致性（路C B-3 收口）', () {
    final d = AppThemeSpec.dark;
    final xs = d.shadows.xs.single;
    expect(hex(xs.color), hex(const Color(0x59000000)));
    expect(xs.blurRadius, 6);
    expect(xs.offset, const Offset(0, 2));
    final md = d.shadows.md.single;
    expect(hex(md.color), hex(const Color(0x80000000)));
    expect(md.blurRadius, 12);
    expect(md.offset, const Offset(0, 4));
 // 单源断言：shadows 必须派生自 colors（改 colors 即生效）。
    expect(identical(d.shadows.xs.single.color, d.colors.shadowXs), isTrue);
    expect(identical(d.shadows.md.single.color, d.colors.shadowMd), isTrue);
    expect(identical(
        AppThemeSpec.light.shadows.xs.single.color,
        AppThemeSpec.light.colors.shadowXs), isTrue);
  });

  test('深色槽位收口断言（批3 复扫 B-2 补靶：三波修复的槽位值全锁）', () {
    final t = buildAppTheme(Brightness.dark);
    final c = AppThemeSpec.dark.colors;
    expectHex(t.canvasColor, 0xFF2B2B2B, 'canvasColor=card');
    expectHex(t.colorScheme.inversePrimary, 0xFF4099FF, 'inversePrimary');
    expectHex(t.colorScheme.onSurface, 0xFFD4D4D4, 'onSurface=foreground');
    expectHex(t.colorScheme.onSurfaceVariant, 0x99D4D4D4, 'onSurfaceVariant=subtle');
    expectHex(t.colorScheme.outline, 0x26FFFFFF, 'outline=borderHover');
    expectHex(t.colorScheme.outlineVariant, 0x14FFFFFF, 'outlineVariant=borderFaint');
    expectHex(t.colorScheme.surfaceContainerHigh, 0xFF2B2B2B, 'surfaceContainerHigh');
    expectHex(t.colorScheme.inverseSurface, 0xFF2B2B2B, 'inverseSurface=card');
    expectHex(t.dialogTheme.backgroundColor!, 0xFF2B2B2B, 'dialogTheme');
    expectHex(t.bottomSheetTheme.backgroundColor!, 0xFF2B2B2B, 'bottomSheetTheme');
    expectHex(t.popupMenuTheme.color!, 0xFF2B2B2B, 'popupMenuTheme');
    expectHex(t.textSelectionTheme.selectionColor!, 0x474099FF,
        'textSelection=官方终端选区蓝');
    expectHex(t.textTheme.bodyMedium!.color!, 0xFFD4D4D4,
        'textTheme.bodyMedium=foreground（烤色收口）');
    expectHex(t.textTheme.bodySmall!.color!, 0xFFD4D4D4, 'textTheme.bodySmall');
 // 浅色侧对应槽必须保持出厂（null 直通语义抽验：非空即错）。
    final lt = buildAppTheme();
    expect(lt.dialogTheme.backgroundColor, isNull, reason: '浅色 dialogTheme 直通');
    expect(lt.canvasColor, isNot(equals(0xFF2B2B2B)), reason: '浅色 canvasColor 出厂');
 // 浅色 textTheme 出厂即烤 #1D1B20（M3 light onSurface——A3 审查 B2
 // 记录在案的既有浅色行为）；钉住该值防漂移（改动须解锁）。
    expectHex(lt.textTheme.bodyMedium!.color!, 0xFF1D1B20,
        '浅色 textTheme 出厂烤色');
 // 引用一致性：槽位与色板同源。
    expect(identical(t.colorScheme.onSurface, c.foreground), isTrue);
    expect(identical(t.canvasColor, c.card), isTrue);
  });

  test('buildAppTheme(dark) 挂载深色套+ThemeData 关键输出', () {
    final t = buildAppTheme(Brightness.dark);
    expectHex(t.scaffoldBackgroundColor, 0xFF161616, 'scaffold');
    expectHex(t.colorScheme.primary, 0xFFFFFFFF, 'primary(反转)');
    expectHex(t.colorScheme.onPrimary, 0xFF000000, 'onPrimary');
    expectHex(t.appBarTheme.backgroundColor!, 0xFF202020, 'appBar');
    expectHex(t.cardTheme.color!, 0xFF2B2B2B, 'card');
    expectHex(t.floatingActionButtonTheme.backgroundColor!, 0xFF4099FF,
        'fab(brandAccent)');
    final spec = t.extension<AppThemeSpec>();
    expect(spec, isNotNull, reason: 'ThemeExtension 必须挂载');
    expect(identical(spec!.colors, AppThemeSpec.dark.colors), isTrue,
        reason: 'dark ThemeData 必须携带深色套实例');
  });

  test('buildAppTheme()（默认）与 light 套实例一致', () {
    final t = buildAppTheme();
    final spec = t.extension<AppThemeSpec>();
    expect(identical(spec!.colors, AppThemeSpec.light.colors), isTrue,
        reason: '默认 ThemeData 必须携带浅色套实例（回归红线）');
  });
}
