import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 模型品牌 → 官方 logo 矢量资产映射（Paseo 参考批，2026-10-23 用户
/// 拍板："用真实的 logo，不要程序手绘"）。
///
/// 资产来源（assets/brand_logos/，全部为品牌官方图形的忠实单色转写，
/// path 数据原样保留，仅统一无填充由运行时染色）：
/// - anthropic/gemini/deepseek/moonshotai/qwen：Simple Icons 官方 path
///   （品牌官方标志的单色矢量转写，CC0）。
/// - openai/mistralai/meta：Simple Icons 同源同工艺补齐（2026-10-24
/// 修复批 拍板）。
/// - x/xiaomi/minimax/nvidia：Simple Icons 同源同工艺补齐（2026-11-05
///   反馈④"各模型 logo 充分补齐"——xAI 的 X 形标已被收录（slug=x，与
///   xAI 官方同形）；OCG 常见第三方品牌覆盖 mimo/minimax/nemotron。
///   stepfun/volcengine(doubao)/tencent(hunyuan) 仍未被收录，保持
///   中性点回退，收录后再补）。
/// - zhipu：Z.ai 官方 CDN（z-cdn.chatglm.cn/z-ai/static/logo.svg）的
///   Z 字标三形状（原 path 数据，去底板/描边单色化）。
/// 渲染时 colorFilter 染当前文字色——不引入彩色（"彩色仅点睛"定调）。
/// 缺失品牌返回 null 回退纯文字，不留空位。
String? brandLogoAsset(String modelId) {
  final id = modelId.toLowerCase();
  if (id.contains('glm') ||
      id.contains('zhipu') ||
      id.contains('chatglm') ||
      // 智谱系非 GLM 命名模型（2026-11-05 反馈④：codegeex/charglm/
      // emohaa 落 dot 的漏网归并）。
      id.contains('codegeex') ||
      id.contains('charglm') ||
      id.contains('emohaa')) {
    return 'assets/brand_logos/zhipu.svg';
  }
  if (id.contains('claude')) return 'assets/brand_logos/claude.svg';
  if (id.contains('gemini')) return 'assets/brand_logos/googlegemini.svg';
  if (id.contains('deepseek')) return 'assets/brand_logos/deepseek.svg';
  // 小米 MiMo（2026-11-05 反馈④用户点名）：官方 provider 图标即小米标。
  if (id.contains('mimo') || id.contains('xiaomi')) {
    return 'assets/brand_logos/xiaomi.svg';
  }
  if (id.contains('minimax')) return 'assets/brand_logos/minimax.svg';
  // xAI Grok：X 形标（Simple Icons slug=x，与 xAI 官方同形）。
  if (id.contains('grok') || id.contains('x-ai')) {
    return 'assets/brand_logos/x.svg';
  }
  if (id.contains('nemotron') || id.contains('nvidia')) {
    return 'assets/brand_logos/nvidia.svg';
  }
  if (id.contains('kimi') ||
      id.contains('moonshot') ||
      // Kimi K 系新档 id 不带 kimi 字样（k3.1-pro，2026-10-25 真机实锤）
      // ——k+数字须词边界（grok-3 的 k 前是字母，不命中）。
      // 2026-10-26 真机验收①：moonshotai.svg=公司标被用户判错——官方
      // 桌面用 Kimi 品牌标（refs ProviderLogo.tsx:12 moonshot-kimi 资产）
      // → 换 Simple Icons kimi 官方标（同源同工艺）。
      RegExp(r'(^|[^a-z0-9])k\d').hasMatch(id)) {
    return 'assets/brand_logos/kimi.svg';
  }
  if (id.contains('qwen') || id.contains('qwq')) {
    return 'assets/brand_logos/qwen.svg';
  }
  if (id.contains('openai') ||
      id.contains('gpt') ||
      // o1/o3/o4 系需词边界（裸 contains('o1') 会误吞任何含 o1 的 id）。
      RegExp(r'(^|[^a-z0-9])o[134]($|[^a-z0-9])').hasMatch(id)) {
    return 'assets/brand_logos/openai.svg';
  }
  if (id.contains('mistral') ||
      id.contains('ministral') ||
      id.contains('codestral') ||
      id.contains('magistral') ||
      id.contains('devstral')) {
    return 'assets/brand_logos/mistralai.svg';
  }
  if (id.contains('llama')) return 'assets/brand_logos/meta.svg';
  return null;
}

/// 品牌色表（2026-10-26 用户拍板①：浅色模式上品牌原色——黑白跟随文字
/// 色只服务深色可见度，浅色沿用同一逻辑属配色走样）。
/// 来源与勘误（2026-10-26 用户复核纠偏：**模型/产品品牌色≠公司品牌色**，
/// 且以官方桌面 provider 图标实测为最高锚点）：
/// - deepseek 4D6BFE：官方图标实测蓝（provider-icons PNG 主色）✔；
/// - qwen 615CED / gemini 8E75B2 / mistral FF7000 / claude D97757：
///   产品品牌色（SI 产品条目/用户拍板）✔；
/// - **智谱（glm/zhipu）与 OpenAI（gpt/o 系）不入表**：官方桌面三枚
///   智谱系图标全为单色标（zai/zai-app 黑、bigmodel 白——实测 PNG/SVG
///   填色），OpenAI 官方图标亦为黑标（SI 的 412991 存疑不采）——均归
///   近黑单色类，浅色近黑可见、深色退文字色（与 Kimi 同档）。
const Map<String, Color> _brandColors = {
  'assets/brand_logos/claude.svg': Color(0xFFD97757),
  'assets/brand_logos/deepseek.svg': Color(0xFF4D6BFE),
  'assets/brand_logos/qwen.svg': Color(0xFF615CED),
  'assets/brand_logos/mistralai.svg': Color(0xFFFF7000),
  'assets/brand_logos/googlegemini.svg': Color(0xFF8E75B2),
  'assets/brand_logos/meta.svg': Color(0xFF0467DF),
  'assets/brand_logos/xiaomi.svg': Color(0xFFFF6900),
  'assets/brand_logos/minimax.svg': Color(0xFFE73562),
  'assets/brand_logos/nvidia.svg': Color(0xFF76B900),
  // Kimi/X(xAI)=品牌黑白（近黑类）：浅色用原色黑；深色提亮无意义→退前景色。
  'assets/brand_logos/kimi.svg': Color(0xFF000000),
  'assets/brand_logos/x.svg': Color(0xFF000000),
};

/// 品牌色深浅解析（2026-10-26 拍板①A）：
/// - 浅色模式=品牌原色；
/// - 深色模式=提亮品牌色（HSL 亮度抬到 0.72，保识别又保对比）；
/// - 近黑品牌（Kimi 等亮度 <0.12）深色下提亮即失去品牌感→返回 null
///   由调用侧退前景色。
Color? resolveBrandColor(String asset, Brightness brightness) {
  final brand = _brandColors[asset];
  if (brand == null) return null;
  final hsl = HSLColor.fromColor(brand);
  if (brightness == Brightness.light) return brand;
  if (hsl.lightness < 0.12) return null;
  if (hsl.lightness < 0.72) {
    return hsl.withLightness(0.72).toColor();
  }
  return brand;
}

/// 品牌小 logo。[color] 显式传入=沿用旧单色路径（欢迎屏水印等中性
/// 装饰用法）；null=品牌色自动策略（浅色原色/深色提亮，见
/// [resolveBrandColor]）。
class BrandLogo extends StatelessWidget {
  final String asset;
  final double size;
  final Color? color;

  const BrandLogo({
    super.key,
    required this.asset,
    this.size = 16,
    this.color,
  });

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        asset,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(
          color ??
              resolveBrandColor(asset, Theme.of(context).brightness) ??
              Theme.of(context).colorScheme.onSurface,
          BlendMode.srcIn,
        ),
      );
}
