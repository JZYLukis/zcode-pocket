/// 设计 token 单源（官方 zai-light/zai-dark design tokens，ZCode 官方开源实现
/// packages/ui/src/styles.css:492-636 / 638-783）。
/// 深色模式批 1：色板从「单套静态常量」重构为「浅/深双套
/// 实例 + ThemeExtension 挂载 + 上下文读取」——切换全 app 自动刷新，
/// 未来色盲模式/皮肤=加数据实例零改消费代码。
/// 浅色值=回归红线（test/theme_freeze_test.dart 冻结，改动须显式解锁）。
/// chrome 材质规范见 （V1 审美优化 2026-10-22：
/// chrome 统一实体白，GlassChrome 退役）。
library;

import 'package:flutter/material.dart';

/// 语义色板（一套=一个亮度形态）。浅色=官方 zai-light 镜像（冻结），
/// 深色=官方 zai-dark 1:1 搬运（dark-mode-plan 底账）。
/// 消费方一律经 `context.colors.xxx` 读取当前套（AppThemeSpec 扩展），
/// 禁止绕过主题机制缓存色值（CustomPainter 需要颜色时从 build 传参）。
class AppColors {
  const AppColors({
    required this.background,
    required this.header,
    required this.sidebar,
    required this.card,
    required this.inputSurface,
    required this.surface,
    required this.surfaceHover,
    required this.selected,
    required this.border,
    required this.borderFaint,
    required this.borderHover,
    required this.brand,
    required this.onBrand,
    required this.brandAccent,
    required this.brandAccentBright,
    required this.onBrandAccent,
    required this.secondary,
    required this.accent,
    required this.foreground,
    required this.foregroundSubtle,
    required this.foregroundSubtlest,
    required this.success,
    required this.destructive,
    required this.warning,
    required this.running,
    required this.linkBlue,
    required this.idleTask,
    required this.idleTaskSurface,
    required this.documentPaper,
    required this.interactionAskSurface,
    required this.interactionAskForeground,
    required this.interactionConfirmSurface,
    required this.interactionConfirmForeground,
    required this.diffAdded,
    required this.diffRemoved,
    required this.shadowXs,
    required this.shadowMd,
  });

  final Color background;
  final Color header;
  final Color sidebar;
  final Color card;

  /// 输入卡专用底（Paseo 参考 2026-10-23 用户拍板：深色降一档向"融合
  /// 安静"靠——card 降档只连坐输入卡不连坐 popover/menu/toast；浅色
  /// 与 card 同值零变化）。消费方：conversation 输入卡容器。
  final Color inputSurface;
  final Color surface;
  final Color surfaceHover;
  final Color selected;
  final Color border;

  /// V1 审美优化（方案 A，2026-10-22）：卡片描边单独减淡档，配合阴影
  /// 加重一档用「浮起感」替代「描边感」；全库通用 border 保持官方值
  /// （输入框/分隔线等非卡片描边仍用 border）。
  final Color borderFaint;
  final Color borderHover;

  /// 主按钮色：浅=黑底白字，深=黑白反转（官方 dark --color-primary 做法
  /// ——纯黑按钮在近黑底 #161616 上隐形， 拍板④）。
  final Color brand;
  final Color onBrand;

  /// 品牌强调色=智谱蓝。浅=#134CFF（开放平台主蓝，白字 6.0:1 过 AA），
  /// 只做点睛位（FAB/发送键按下态/空态插图/扫码框线/配对页主视觉点缀）。
  /// 深=官方深蓝基准 #4099FF（批 1 横向校准定稿， 拍板⑤）。
  final Color brandAccent;

  /// 深色下置于品牌蓝淡底上的可读强调字（浅色=brandAccent 本尊；
  /// 2026-11-07：深色 #4099FF 在蓝 10% 底 4.09:1→提亮 #7FB4FF）。
  final Color brandAccentBright;
  final Color onBrandAccent;
  final Color secondary;
  final Color accent;
  final Color foreground;
  final Color foregroundSubtle;
  final Color foregroundSubtlest;
  final Color success;
  final Color destructive;
  final Color warning;

  /// 运行中状态色（浅=琥珀 #B45309 / 深=官方 warning #FF8A30）。
  /// 官方铁证 run-status-presentation.ts:12-17 running=bg-warning+
  /// animate-pulse；#0B7FFF 在官方仅是终端蓝/图表 1 号色/git renamed
  /// 标记，从不用作运行态（评审文档 -1a 勘误实证）。
  final Color running;

  /// 连接中/同步中/上下文进度类指示（连接心智=蓝，官方 terminal blue
  /// 血统）——与运行态琥珀拆开，两语义不再共用一色。
  final Color linkBlue;
  final Color idleTask;
  final Color idleTaskSurface;

  /// 文档查看底色（反馈#9）：html 预览等生成文档固定白底——
  /// 深色主题也不蒙黑（文档查看器约定，同 PDF）。双主题同值白。
  final Color documentPaper;
  final Color interactionAskSurface;
  final Color interactionAskForeground;
  final Color interactionConfirmSurface;
  final Color interactionConfirmForeground;
  final Color diffAdded;
  final Color diffRemoved;

  /// 阴影色（浅=黑低透明；深=裁量：纯黑更高透明档——深底上阴影弱化，
  /// 层次靠亮度分层，dark-mode-plan 裁量格）。
  final Color shadowXs;
  final Color shadowMd;
}

/// 终端色全套（官方 --color-terminal-*，styles.css 浅 :636 段 / 深 677-698）。
/// 批 1 数据层一次搬完；消费方经 `context.terminal.xxx`。
class AppTerminalColors {
  const AppTerminalColors({
    required this.bg,
    required this.fg,
    required this.cursor,
    required this.cursorAccent,
    required this.selection,
    required this.selectionInactive,
    required this.black,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.white,
    required this.brightBlack,
    required this.brightRed,
    required this.brightGreen,
    required this.brightYellow,
    required this.brightBlue,
    required this.brightMagenta,
    required this.brightCyan,
    required this.brightWhite,
  });

  final Color bg;
  final Color fg;
  final Color cursor;
  final Color cursorAccent;
  final Color selection;
  final Color selectionInactive;
  final Color black;
  final Color red;
  final Color green;
  final Color yellow;
  final Color blue;
  final Color magenta;
  final Color cyan;
  final Color white;
  final Color brightBlack;
  final Color brightRed;
  final Color brightGreen;
  final Color brightYellow;
  final Color brightBlue;
  final Color brightMagenta;
  final Color brightCyan;
  final Color brightWhite;
}

/// git 状态色（官方 --color-git-*，styles.css 浅 :111-118 段 / 深 766-774）。
/// 批 1 数据层一次搬完；消费方经 `context.git.xxx`。
class AppGitColors {
  const AppGitColors({
    required this.none,
    required this.modified,
    required this.added,
    required this.deleted,
    required this.renamed,
    required this.untracked,
    required this.ignored,
    required this.descendant,
  });

  final Color none;
  final Color modified;
  final Color added;
  final Color deleted;
  final Color renamed;
  final Color untracked;
  final Color ignored;
  final Color descendant;
}

/// 图表系列配色（批次 B 入单源；深色版=官方 usage-chart 深色 1-5 +
/// 裁量项，dark-mode-plan 图表底账）。
/// 消费方经 `context.charts.xxx`——勿在 painter 外缓存（主题切换失效）。
class AppChartPalette {
  const AppChartPalette({
    required this.series,
    required this.heatmapGreens,
    required this.sourceColors,
  });

  /// 用量图表 6 色（浅=官方 --color-usage-chart-1..6 浅色近似；深=官方
  /// 深色 1..6：#4099FF/#46BF72/#7B5CE5/#FF5C5C/#FF8A30/#42C8C8）。
  final List<Color> series;

  /// 热力图 5 级（level 0-4）。浅=绿阶（历史语义，官方浅色实为蓝阶的
  /// 已知偏差）；深=裁量「绿阶深色版」——保持跨模式同语义（绿色=活跃
  /// 量），阶值批 1 定稿留痕 。
  final List<Color> heatmapGreens;

  /// 上下文来源 7 色（会话页来源圆点，对应 _sourceLabels 7 类）。
  /// 取色必须按 source 字符串确定性映射——勿用对象 hashCode（Map 身份
  /// 哈希跨快照重建会变，同一来源会换色；设计审计 6.5-1 实证）。
  /// 深色=裁量提亮版。
  final List<Color> sourceColors;
}

/// 阴影档位（V1 审美优化：xs 加重一档用浮起感替代描边感；md 统一 blur
/// 12）。深色=同几何、裁量加重透明档。消费方经 `context.shadows.xxx`。
class AppShadows {
  const AppShadows({required this.xs, required this.md});

  final List<BoxShadow> xs;
  final List<BoxShadow> md;
}

/// 主题规格（ThemeExtension）：把当前亮度形态的全套色板挂进主题。
/// lerp 采用阶跃（t<0.5 取旧套）——色板是成对调过的整体，逐 token 插值
/// 会经过未审过的中间色；切换瞬切（官方 web 亦瞬切）。
class AppThemeSpec extends ThemeExtension<AppThemeSpec> {
  const AppThemeSpec({
    required this.colors,
    required this.terminal,
    required this.git,
    required this.charts,
  });

  final AppColors colors;
  final AppTerminalColors terminal;
  final AppGitColors git;
  final AppChartPalette charts;

  /// 阴影档位由 colors.shadowXs/shadowMd 单源派生（ ：
  /// 原先 BoxShadow 字面量与 AppColors 双源同值独立维护，改一处漏一处
  /// 不会被测试抓——派生后只维护 colors 侧，两套测试各自锁值即闭环）。
  AppShadows get shadows => AppShadows(
        xs: [BoxShadow(color: colors.shadowXs, blurRadius: 6, offset: const Offset(0, 2))],
        md: [BoxShadow(color: colors.shadowMd, blurRadius: 12, offset: const Offset(0, 4))],
      );

  /// 浅色套（zai-light 镜像，冻结——test/theme_freeze_test.dart）。
  static final AppThemeSpec light = AppThemeSpec(
    colors: const AppColors(
      background: Color(0xFFF8F8F8),
      header: Color(0xFFFFFFFF),
      sidebar: Color(0xFFF0F0F0),
      card: Color(0xFFFFFFFF),
      inputSurface: Color(0xFFFFFFFF), // 与 card 同值（浅色零变化）
      surface: Color(0x080D0D0D), // rgba(13,13,13,0.03)
      surfaceHover: Color(0x0D0D0D0D), // rgba(13,13,13,0.05)
      selected: Color(0x0D0D0D0D),
      border: Color(0x1A0D0D0D), // rgba(13,13,13,0.10)
      borderFaint: Color(0x140D0D0D), // rgba(13,13,13,0.08)
      borderHover: Color(0x260D0D0D), // 0.15
      brand: Color(0xFF000000),
      onBrand: Color(0xFFFFFFFF),
      brandAccent: Color(0xFF134CFF),
      brandAccentBright: Color(0xFF134CFF), // 浅色=本尊
      onBrandAccent: Color(0xFFFFFFFF),
      secondary: Color(0xFFE6E6E6),
      accent: Color(0xFFEBF4FF),
      foreground: Color(0xFF262626), // neutral-800
      // 对比度修正（2026-10-19 批次4）：subtlest 40%→55%、subtle 60%→70%
      // （原对 #F8F8F8 仅 2.24:1 / 3.88:1，低于 WCAG AA 正文线 4.5:1）。
      // 2026-11-05 反馈④（用户拍板折中档）：subtlest 55%→45%（2.68:1）
      // ——正文与工具行/思考行的层级差此前只做到官方（40% 档）的六成，
      // 官方本档即辅助文字档（tertiary），按官方层级回撤但保留一档可读性；
      // subtle 70% 维持（真正的次要正文，不动）。
      foregroundSubtle: Color(0xB3262626), // 70%
      foregroundSubtlest: Color(0x73262626), // 45%
      // warning/success 加深过 AA（原 #E07B00 2.82:1 / #1E8A3E 4.15:1；
      // amber-700/green-700 量级）。
      success: Color(0xFF15803D),
      // 独立视觉复核必修3（2026-11-07）：E03131 在 destructive@faint
      // 底上=3.79:1 不达 4.5——换 C62828（同底 5.06:1，同族红少饱和
      // 提对比；深色档 FF5C5C=5.43:1 合格不动）。success/warning 同行
      // 注释的 AA 加深先例。
      destructive: Color(0xFFC62828),
      warning: Color(0xFFB45309),
      running: Color(0xFFB45309),
      linkBlue: Color(0xFF0B7FFF),
      idleTask: Color(0xFF9E77ED),
      documentPaper: Colors.white,
      idleTaskSurface: Color(0xFFF5F3FF),
      interactionAskSurface: Color(0xFFEBF4FF),
      interactionAskForeground: Color(0xFF0066DD),
      interactionConfirmSurface: Color(0xFFEAF7EE),
      interactionConfirmForeground: Color(0xFF166B32),
      diffAdded: Color(0xFF1E8A3E),
      diffRemoved: Color(0xFFE03131),
      shadowXs: Color(0x080D0D0D), // 黑 3%（卡片浅投影）
      shadowMd: Color(0x14000000), // 黑 8%（浮层/横幅投影）
    ),
    terminal: const AppTerminalColors(
      bg: Color(0xFFF8F8F8),
      fg: Color(0xFF262626),
      cursor: Color(0xFF0D0D0D),
      cursorAccent: Color(0xFFF8F8F8),
      selection: Color(0x380B7FFF), // rgba(11,127,255,0.22)
      selectionInactive: Color(0x1A0D0D0D),
      black: Color(0xFF5C5C5C),
      red: Color(0xFFE03131),
      green: Color(0xFF1E8A3E),
      yellow: Color(0xFFE07B00),
      blue: Color(0xFF0B7FFF),
      magenta: Color(0xFF9E77ED),
      cyan: Color(0xFF0AA7A7),
      white: Color(0xFFADADAD),
      brightBlack: Color(0xFF888888),
      brightRed: Color(0xFFE03131),
      brightGreen: Color(0xFF1E8A3E),
      brightYellow: Color(0xFFE07B00),
      brightBlue: Color(0xFF0066DD),
      brightMagenta: Color(0xFF9E77ED),
      brightCyan: Color(0xFF0AA7A7),
      brightWhite: Color(0xFF0D0D0D),
    ),
    git: const AppGitColors(
      none: Color(0xFF262626),
      modified: Color(0xFFE07B00),
      added: Color(0xFF1E8A3E),
      deleted: Color(0xFFE03131),
      renamed: Color(0xFF0B7FFF),
      untracked: Color(0xFF1E8A3E),
      ignored: Color(0x8C262626), // = foregroundSubtlest 55%
      descendant: Color(0xFFE07B00),
    ),
    charts: const AppChartPalette(
      series: [
        // 官方 zai-light usage-chart-1..6（styles.css，2026-10-26
        // 对齐轮替换——原 5 色系 tailwind-600 自选非官方）。
        Color(0xFF0B7FFF), // chart-1 蓝
        Color(0xFF1E8A3E), // chart-2 绿
        Color(0xFF9E77ED), // chart-3 紫
        Color(0xFFE03131), // chart-4 红
        Color(0xFFE07B00), // chart-5 橙
        Color(0xFF0AA7A7), // chart-6 青
      ],
      heatmapGreens: [
        Color(0xFFEBEDF0),
        Color(0xFFC6E9C4),
        Color(0xFF8CD98A),
        Color(0xFF4CAF50),
        Color(0xFF217A2B),
      ],
      sourceColors: [
        Color(0xFF2563EB),
        Color(0xFF16A34A),
        Color(0xFFEA580C),
        Color(0xFF9333EA),
        Color(0xFF0891B2),
        Color(0xFF64748B),
        Color(0xFFDB2777),
      ],
    ),
  );

  /// 深色套（官方 zai-dark 1:1 搬运，styles.css:638-783；裁量项留痕
  /// dark-mode-plan + 批 1 补记）。
  static final AppThemeSpec dark = AppThemeSpec(
    colors: const AppColors(
      background: Color(0xFF161616),
      header: Color(0xFF202020),
      sidebar: Color(0xFF161616), // 与主背景同色（官方同构）
      card: Color(0xFF2B2B2B), // input/popover/menu/toast 深色同 #2B2B2B
      inputSurface: Color(0xFF232322), // 输入卡深色降一档（Paseo 融合感；保留描边）
      surface: Color(0x0DFFFFFF), // 白 5%
      surfaceHover: Color(0x1AFFFFFF), // 白 10%
      selected: Color(0x1AFFFFFF), // 官方深色 selected=白 10%
      border: Color(0x1AFFFFFF), // 白 10%
      borderFaint: Color(0x14FFFFFF), // 白 8%（浅色同语义自定档）
      borderHover: Color(0x26FFFFFF), // 白 15%
      brand: Color(0xFFFFFFFF), // 黑白反转（拍板④）
      onBrand: Color(0xFF000000),
      // 智谱蓝深色基准 #4099FF（官方深蓝/terminal-blue，拍板⑤；批 1
      // 横向校准后如偏离须回填此处+决策记录 留痕）。
      brandAccent: Color(0xFF4099FF),
      brandAccentBright: Color(0xFF7FB4FF), // 深色提亮档（淡底上≈5.8:1）
      // 批1-5 横向校准定稿（ 补记）：#4099FF 实底配白图标仅
      // 2.91:1（低于 3:1 非文本线）；改深蓝前景 #001D3D=5.81:1（GitHub
      // accent.emphasis 压暗路线的镜像——亮底深前景，paseo zinc 同构）。
      onBrandAccent: Color(0xFF001D3D),
      secondary: Color(0xFF363636),
      accent: Color(0xFF001D3D),
      foreground: Color(0xFFD4D4D4), // neutral-300
      // ⚠ 官方值起步（白60%/白30%）。路B 视觉走查 （2026-10-23）：30%
      // 档像素实测 3.3:1，低于浅色同位——按底账"浅色同逻辑等效果"曾提亮
      // 至 47%。2026-11-05 反馈④随浅色 subtlest 55%→45%（2.68:1）等效果
      // 对齐回撤至 36%（2.67:1）；subtle 60% 维持（bg 上 4.85:1 过线；
      // 卡上 4.49 临界，批 2 对比度单测定档复核）。
      foregroundSubtle: Color(0x99D4D4D4), // 60%
      foregroundSubtlest: Color(0x5CD4D4D4), // 36%（等效果随浅色回撤）
      // 官方深色即提亮版（success #46bf72 / warning #ff8a30），直接用；
      // ⚠ 批 2 对比度单测复核（底账标注）。
      success: Color(0xFF46BF72),
      destructive: Color(0xFFFF5C5C),
      warning: Color(0xFFFF8A30),
      running: Color(0xFFFF8A30),
      linkBlue: Color(0xFF4099FF),
      idleTask: Color(0xFF7B5CE5),
      documentPaper: Colors.white,
      idleTaskSurface: Color(0xFF160D38),
      interactionAskSurface: Color(0xFF001D3D),
      interactionAskForeground: Color(0xFF80BEEF),
      interactionConfirmSurface: Color(0x2946BF72), // rgba(70,191,114,0.16)
      interactionConfirmForeground: Color(0xFF87D9A4),
      diffAdded: Color(0xFF46BF72),
      diffRemoved: Color(0xFFFF5C5C),
      // 裁量（批 1 定稿留痕）：深底阴影弱化、层次靠亮度分层——纯黑更高
      // 透明档（浅色 3%/8% → 深色 35%/50%，截图校准）。
      shadowXs: Color(0x59000000), // 黑 35%
      shadowMd: Color(0x80000000), // 黑 50%
    ),
    terminal: const AppTerminalColors(
      bg: Color(0xFF161616), // = background
      fg: Color(0xFFD4D4D4), // = foreground
      cursor: Color(0xFFF8F8F8),
      cursorAccent: Color(0xFF161616),
      selection: Color(0x474099FF), // rgba(64,153,255,0.28)
      selectionInactive: Color(0x1AFFFFFF),
      black: Color(0xFF363636),
      red: Color(0xFFFF5C5C),
      green: Color(0xFF46BF72),
      yellow: Color(0xFFFF8A30),
      blue: Color(0xFF4099FF),
      magenta: Color(0xFF7B5CE5),
      cyan: Color(0xFF42C8C8),
      white: Color(0xFFADADAD),
      brightBlack: Color(0xFF747474),
      brightRed: Color(0xFFFF9999),
      brightGreen: Color(0xFF87D9A4),
      brightYellow: Color(0xFFFFB26B),
      brightBlue: Color(0xFF80BEFF),
      brightMagenta: Color(0xFFA888F2),
      brightCyan: Color(0xFF8EE5E5),
      brightWhite: Color(0xFFF8F8F8),
    ),
    git: const AppGitColors(
      none: Color(0xFFD4D4D4),
      modified: Color(0xFFFF8A30),
      added: Color(0xFF46BF72),
      deleted: Color(0xFFFF5C5C),
      renamed: Color(0xFF4099FF),
      untracked: Color(0xFF46BF72),
      ignored: Color(0x4DD4D4D4), // 官方原值 30%（v foreground-subtlest 的
      // 渲染值快照；官方语义为引用跟随，subtlest 校准至 47% 后本值不联动——
      // 保官方渲染值更贴 zai-dark，接线消费时如观感不足再议）
      descendant: Color(0xFFFF8A30),
    ),
    // series=官方 usage-chart 深色前 5；热力图=裁量绿阶深色版（保语义，
    // 官方深色实为蓝阶——与浅色同型偏差，留痕）；来源 7 色=裁量提亮版。
    charts: const AppChartPalette(
      series: [
        // 官方 zai-dark usage-chart-1..6（前 5 色原已一致，补第 6 色）。
        Color(0xFF4099FF), // chart-1
        Color(0xFF46BF72), // chart-2
        Color(0xFF7B5CE5), // chart-3
        Color(0xFFFF5C5C), // chart-4
        Color(0xFFFF8A30), // chart-5
        Color(0xFF42C8C8), // chart-6（2026-10-26 对齐轮补）
      ],
      // 批1-5 校准（GitHub 贡献图同构）：状态绿只做中间档，顶档更亮
      // 增满格冲击力（GitHub #3fb950→#7ee787 同款思路，顶档略压）。
      heatmapGreens: [
        Color(0xFF252B28),
        Color(0xFF1B4531),
        Color(0xFF247A4B),
        Color(0xFF46BF72),
        Color(0xFF6FD98A),
      ],
      sourceColors: [
        Color(0xFF4099FF),
        Color(0xFF46BF72),
        Color(0xFFFF8A30),
        Color(0xFF7B5CE5),
        Color(0xFF42C8C8),
        Color(0xFFADADAD),
        Color(0xFFF472B6),
      ],
    ),
  );

  @override
  AppThemeSpec copyWith({
    AppColors? colors,
    AppTerminalColors? terminal,
    AppGitColors? git,
    AppChartPalette? charts,
  }) =>
      AppThemeSpec(
        colors: colors ?? this.colors,
        terminal: terminal ?? this.terminal,
        git: git ?? this.git,
        charts: charts ?? this.charts,
      );

  @override
  AppThemeSpec lerp(AppThemeSpec? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// 上下文读取扩展：`context.colors.border` / `context.charts.series` /
/// `context.terminal.blue` / `context.git.added` / `context.shadows.md`。
/// 一切颜色消费走这里（编译器保证迁移完整性：静态常量已拆除）。
///
/// 扩展缺失时回退浅色套：裸 MaterialApp 测试 harness 的语义=迁移前
/// 静态常量（恒浅色），回退保持等价；生产唯一 ThemeData 构造点
/// buildAppTheme 必挂扩展（theme_dark_snapshot_test 断言把守）。
extension AppThemeSpecX on BuildContext {
  AppThemeSpec get _spec =>
      Theme.of(this).extension<AppThemeSpec>() ?? AppThemeSpec.light;
  AppColors get colors => _spec.colors;
  AppTerminalColors get terminal => _spec.terminal;
  AppGitColors get git => _spec.git;
  AppChartPalette get charts => _spec.charts;
  AppShadows get shadows => _spec.shadows;
}

/// 字阶（基准 14px，styles.css:171-183）；移动输入框 ≥16px 防聚焦缩放。
/// 批次4：uiXs 10→11（10px 正文级文字低于可读下限——审查对比度项）。
/// 两主题通用，不拆分。
abstract final class AppType {
  static const uiXl = 18.0;
  static const uiLg = 16.0;
  static const uiBase = 14.0;
  static const uiCaption = 13.0;
  static const uiSm = 12.0;
  static const uiXs = 11.0;
  static const mobileInputSafe = 16.0;
}

/// 圆角语言。两主题通用，不拆分。
abstract final class AppRadius {
  static const sm = 8.0; // 小控件
  static const bubble = 12.0; // 气泡（右上 2px 指向）
  static const block = 12.0; // 代码块（官方 rounded-xl，）
  static const bubbleTail = 2.0; // 气泡右上指向角（官方 rounded-tr-xs；批次 B 入单源）
  static const card = 16.0; // 输入卡/审批卡/弹窗
  static const glassChrome = 20.0; // 悬浮 chrome 容器（输入卡/悬浮胶囊）
  // V1 审美优化：胶囊档入 token（原先 11 处手写 999 靠 scanner 合法值集
  // 豁免；Flutter 会把 999 钳到半高，语义=完全胶囊）。
  static const pill = 999.0;
}

/// 透明度档位（V1 审美优化 2026-10-22：原先 13 种取值 41 处散落
/// withValues(alpha:) 字面量，归档为语义档；低频散值 V4 收尾对账）。
/// 两主题通用，不拆分（深底上观感档位批 3 校）。
abstract final class AppAlpha {
  static const faint = 0.08; // 状态底色/提示条底
  static const light = 0.10; // 状态胶囊底（status_badge 同款）
  static const mid = 0.35; // 次级描边/遮罩
  static const strong = 0.45; // 描边强调
  static const heavy = 0.6; // 高对比遮罩
  // 空态欢迎屏 Z 水印（2026-10-23 用户反馈批⑥，对齐官方欢迎屏
  // 「若隐若现」定调：官方浅=foreground-subtlest 线框+.7 透明、
  // 深=暗资产渐变 #444→#1A1A1A，双主题取同一净观感档——
  // 首版 0.12 目检偏强半档，收到 0.08「第二眼才注意到」档）。
  static const watermark = 0.08;
}

/// 空态欢迎屏 Z 水印下端渐隐遮罩（2026-10-23 用户反馈批⑥；ShaderMask
/// dstIn 用——白=遮罩全透通道、透明=渐隐，非渲染色，官方 mask-image
/// linear-gradient(to bottom, black 0, transparent 70%→100%) 同款语义）。
const LinearGradient kBottomFadeMask = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Colors.white, Colors.white, Colors.transparent],
  stops: [0, 0.7, 1.0],
);

/// 基座 ThemeData 模块级单例：基座构造是
/// 全量组件默认计算（M3 出厂全套），原先深色分支单次 buildAppTheme 要
/// 构造 3 个完整 ThemeData（base + textTheme.apply 底 + primaryTextTheme
/// .apply 底），MaterialApp 每次重建 theme/darkTheme 各调一次=最多 6 个。
/// 共享不可变基座后各剩 1 次；copyWith 不改基座本身。
final ThemeData _lightBaseTheme = ThemeData.light(useMaterial3: true);
final ThemeData _darkBaseTheme = ThemeData.dark(useMaterial3: true);

/// 构建主题（浅色=默认，保持既有调用点不变；深色=MaterialApp.darkTheme）。
/// 色板经 ThemeExtension 挂载，消费方用 context.colors 等读取。
ThemeData buildAppTheme([Brightness brightness = Brightness.light]) {
  final spec = brightness == Brightness.dark ? AppThemeSpec.dark : AppThemeSpec.light;
  final c = spec.colors;
  final isDark = brightness == Brightness.dark;
  final base = isDark ? _darkBaseTheme : _lightBaseTheme;
  return base.copyWith(
    scaffoldBackgroundColor: c.background,
    // 2026-11-05 反馈②D：Android 默认 FadeForwards 450ms（旧页 112ms
    // 即淡出、新页 337ms 才全亮）=「进窗口闪一下+等一下」观感的固定
    // 背景之一（本机 3.47.7 默认 PredictiveBack→程序化 push 回退
    // FadeForwards）。换经典 Zoom 300ms（缩放+淡入更干脆；iOS 保持
    // 出厂）。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
      },
    ),
    colorScheme: base.colorScheme.copyWith(
      primary: c.brand,
      onPrimary: c.onBrand,
      secondary: c.secondary,
      surface: c.card,
      error: c.destructive,
      brightness: brightness,
      // B （2026-10-23）：M3 默认 surfaceContainer*/secondaryContainer
      // 等槽位带紫调（#2B2930/#4A4458 系），深色下大面积漏出（弹层/chip/
      // snackbar/未覆盖文字）——深色分支收口到官方灰阶；浅色侧 2026-11-07
      // 用户拍板同批收口到**智谱蓝图系**（「纯黑白过于冷淡」——原紫调
      // 槽位一律换 brandAccent #134CFF 在白上的低饱和梯度，不再保持出厂）。
      onSurface: isDark ? c.foreground : null,
      // 浅色 onSurfaceVariant 出厂 #49454F（紫灰）：字数计数器等未覆盖文字
      // 比自己的标签还黑（层级倒挂）——回中性 subtle 档。
      onSurfaceVariant: c.foregroundSubtle,
      outline: isDark ? c.borderHover : null,
      // 批3（像素复检）：ActionChip 默认边框走 outlineVariant（M3 出厂
      // #48454F 紫灰，深色下 1.9:1 过暗）——深色收口到 borderFaint；
      // 浅色出厂 #CAC4D0 紫灰同步收口（'）。
      outlineVariant: c.borderFaint,
      // 容器族（路B 残余补齐）：M3 surfaceContainer* 各档紫调全数
      // 收口——深色=三档背景语义（lowest=bg/low=header/中高=card）；
      // 浅色=智谱蓝梯度（白 → 4% → 6% → 8% → 10%，蓝调随层级加深）。
      surfaceDim: isDark ? c.background : null,
      surfaceBright: isDark ? c.card : null,
      surfaceContainerLowest: isDark ? c.background : const Color(0xFFFFFFFF),
      surfaceContainerLow: isDark
          ? c.header
          : const Color(0xFFF6F8FF), // 蓝 4%：弹层/滚动 AppBar 最淡档
      surfaceContainer: isDark
          ? c.card
          : const Color(0xFFF1F4FF), // 蓝 6%
      surfaceContainerHigh: isDark ? c.card : const Color(0xFFECF1FF), // 蓝 8%
      surfaceTint: const Color(0x00000000),
      secondaryContainer: isDark
          ? c.selected
          : const Color(0xFFE8EDFF), // 蓝 10%：chip 选中默认容器
      onSecondaryContainer: isDark ? c.foreground : c.brandAccent,
      surfaceContainerHighest: isDark
          ? c.selected
          : const Color(0xFFE8EDFF), // 蓝 10%
      // SnackBar（inverse 族）：浅色出厂 #322F35 紫黑——藏青蓝黑。
      inverseSurface: isDark ? c.card : const Color(0xFF2B313C),
      onInverseSurface: isDark ? c.foreground : const Color(0xFFFFFFFF),
      // 波2 路 ：inversePrimary 恒作 SnackBarAction 文字色（五态皆然），
      // 纯黑在 #2B2B2B 上≈2:1 撤销键隐形——深色 brandAccent（≈4:1）；
      // 浅色藏青底上用亮蓝（#9DB9FF ≈6:1）。
      inversePrimary: isDark ? c.brandAccent : const Color(0xFF9DB9FF),
    ),
    // 波2 路 ：ThemeData.dark 把出厂 surface #141218 固化进 canvasColor
    // （copyWith colorScheme 不会重算该槽），DropdownButton 菜单底走它——
    // 深色收口到 card（官方 popover 基准）。
    canvasColor: isDark ? c.card : null,
    // 闭环（2026-10-23 像素实证）：ThemeData.dark 同样把出厂
    // onSurface #E6E0E9 烤进 textTheme 全系（bodyMedium/bodySmall/...）与
    // indicatorColor——所有未显式设色的文字（设置页行标题/任务卡副标题/
    // 会话正文默认继承链）在深色下漏薰衣草白且比正文更亮（层级颠倒）。
    // apply 重铸为中性前景。
    textTheme: isDark
        ? base.textTheme
            .apply(bodyColor: c.foreground, displayColor: c.foreground)
        : null,
    primaryTextTheme: isDark
        ? base.primaryTextTheme
            .apply(bodyColor: c.onBrand, displayColor: c.onBrand)
        : null,
    // 弹层族收口（路B 主体）：官方 popover/menu/toast 深色=#2B2B2B；
    // 浅色 sheet 面=智谱蓝 4%（' 2026-11-07 用户拍板蓝系取代出厂紫调）。
    dialogTheme: isDark ? DialogThemeData(backgroundColor: c.card) : null,
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark
          ? c.card
          : const Color(0xFFF6F8FF), // 蓝 4%（=surfaceContainerLow）
      dragHandleColor: c.foregroundSubtle,
    ),
    popupMenuTheme: isDark ? PopupMenuThemeData(color: c.card) : null,
    // 文本选区（路B 顺带收口）：深色下默认=primary 纯白块压浅字不可读，
    // 用官方终端选区蓝（rgba(64,153,255,0.28)）。
    textSelectionTheme: isDark
        ? TextSelectionThemeData(
            selectionColor: spec.terminal.selection,
            cursorColor: c.brandAccent,
          )
        : null,
    appBarTheme: AppBarTheme(
      backgroundColor: c.header,
      foregroundColor: c.foreground,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: c.foreground,
        fontSize: AppType.uiLg,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: c.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
        // V1 方案 A：卡片描边用 borderFaint，描边感弱化、阴影浮起。
        side: BorderSide(color: c.borderFaint),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.foreground),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.brand,
        foregroundColor: c.onBrand,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.sm)),
        ),
      ),
    ),
    // V1 审美优化：FAB 显式配置（原先走 M3 默认容器色，渲染为未配置的
    // 紫调底）——新建任务键是品牌点睛位之一。
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.brandAccent,
      foregroundColor: c.onBrandAccent,
    ),
    extensions: [spec],
  );
}
