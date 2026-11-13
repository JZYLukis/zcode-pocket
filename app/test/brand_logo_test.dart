// 品牌 logo 映射回归（问题① 2026-10-25：Kimi K3 系 id=k3.1-pro 不带
// kimi 字样导致药丸无 logo——真机实锤后补词边界匹配；本表锁映射防回归）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/brand_logo.dart';

void main() {
  test('各品牌 id 形态命中正确资产', () {
    final cases = <String, String?>{
      // 智谱（Z 字标）
      'glm-5.3': 'assets/brand_logos/zhipu.svg',
      'glm-5.3-flash': 'assets/brand_logos/zhipu.svg',
      'chatglm-6': 'assets/brand_logos/zhipu.svg',
      // Kimi：老形态带 kimi/moonshot 字样，K3 系新形态裸 k+数字
      'kimi-k2.6': 'assets/brand_logos/kimi.svg',
      'kimi-k2.7-code-highspeed': 'assets/brand_logos/kimi.svg',
      'moonshotai/kimi-k2-turbo-preview': 'assets/brand_logos/kimi.svg',
      'k3.1-pro': 'assets/brand_logos/kimi.svg',
      'K3.1-PRO': 'assets/brand_logos/kimi.svg',
      'moonshot-kimi/k3.1': 'assets/brand_logos/kimi.svg',
      // 其余家抽查
      '早前批次': 'assets/brand_logos/claude.svg',
      'gemini-2.5-pro': 'assets/brand_logos/googlegemini.svg',
      'deepseek-v3': 'assets/brand_logos/deepseek.svg',
      'qwen3-max': 'assets/brand_logos/qwen.svg',
      'gpt-5': 'assets/brand_logos/openai.svg',
      'o3-mini': 'assets/brand_logos/openai.svg',
      'mistral-large': 'assets/brand_logos/mistralai.svg',
      'llama-3': 'assets/brand_logos/meta.svg',
      // 2026-11-05 反馈④新增（OCG 等第三方渠道品牌补齐）：
      'mimo-v2.5': 'assets/brand_logos/xiaomi.svg',
      'mimo-v2.6-pro': 'assets/brand_logos/xiaomi.svg',
      'xiaomi/mimo-v2.5': 'assets/brand_logos/xiaomi.svg',
      'minimax-m3': 'assets/brand_logos/minimax.svg',
      'minimax/minimax-m3': 'assets/brand_logos/minimax.svg',
      'grok-4.6': 'assets/brand_logos/x.svg',
      'x-ai/grok-4.3': 'assets/brand_logos/x.svg',
      'nemotron-52b': 'assets/brand_logos/nvidia.svg',
      // 智谱系非 GLM 命名归并（codegeex/charglm/emohaa）。
      'codegeex-4': 'assets/brand_logos/zhipu.svg',
      'charglm-4': 'assets/brand_logos/zhipu.svg',
      'emohaa': 'assets/brand_logos/zhipu.svg',
    };
    for (final e in cases.entries) {
      expect(brandLogoAsset(e.key), e.value, reason: 'id=${e.key}');
    }
  });

  test('k+数字词边界不误吞他牌', () {
    // grok 的 k 前是字母（o）——不得命中 moonshot（2026-11-05 反馈④
    // xAI 已入 Simple Icons slug=x，改断言命中 x 形标而非 kimi）。
    expect(brandLogoAsset('grok-3'), 'assets/brand_logos/x.svg');
    expect(brandLogoAsset('grok-4'), 'assets/brand_logos/x.svg');
    // 纯文字回退名单保持不变（Simple Icons 未收录品牌不硬凑）。
    expect(brandLogoAsset('hy3'), isNull, reason: '腾讯混元未收录→中性点');
    expect(brandLogoAsset('step-5-preview'), isNull, reason: 'StepFun 未收录');
    expect(brandLogoAsset(''), isNull);
  });

  group('品牌色深浅策略（2026-10-26 拍板①A）', () {
    test('浅色=品牌原色；深色=提亮（HSL≥0.72）', () {
      const deepseek = 'assets/brand_logos/deepseek.svg';
      final light = resolveBrandColor(deepseek, Brightness.light)!;
      expect(light, const Color(0xFF4D6BFE));
      final dark = resolveBrandColor(deepseek, Brightness.dark)!;
      expect(HSLColor.fromColor(dark).lightness,
          greaterThan(0.70),
          reason: '深色下提亮保对比（8bit 往返 0.72≈0.7196，容精度）');
    });

    test('近黑品牌（Kimi）深色退 null（调用侧退前景色），浅色仍原色', () {
      const kimi = 'assets/brand_logos/kimi.svg';
      expect(resolveBrandColor(kimi, Brightness.dark), isNull);
      expect(resolveBrandColor(kimi, Brightness.light), isNotNull,
          reason: '浅色下近黑品牌可见');
    });

    test('无品牌色条目返回 null（显式单色路径继续可用）', () {
      expect(resolveBrandColor('assets/brand_logos/none.svg',
          Brightness.light), isNull);
    });

    test('勘误（2026-10-26 用户复核）：智谱/OpenAI 归单色类——官方桌面'
        '图标实测全单色（zai 黑/bigmodel 白/OpenAI 黑），不采公司色',
        () {
      // 不入色表=两模式都走前景色兜底（浅色近黑可见）。
      expect(resolveBrandColor('assets/brand_logos/zhipu.svg',
          Brightness.light), isNull);
      expect(resolveBrandColor('assets/brand_logos/openai.svg',
          Brightness.dark), isNull);
    });
  });
}
