// 深色模式批 2-5 解锁实施（2026-10-23 用户拍板）回归靶：
// ①tokenizer 双主题着色正确 ②跳过清单/别名/容错 ③开关持久化
// ④端到端 builder 缝（围栏语言经 attributes 流到高亮渲染）。
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_pocket/core/code_highlight.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/ui/markdown_view.dart';

class _Fs extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data[key] = value ?? '';
  }
}

void main() {
  tearDown(debugClearHighlightCache);

  test('dart 关键字/字符串双主题着色（shiki github 同档）', () {
    const code = 'final name = "hi";';
    final light = highlightCode(code, 'dart', brightness: Brightness.light);
    final dark = highlightCode(code, 'dart', brightness: Brightness.dark);
    expect(light, isNotNull);
    expect(dark, isNotNull);
    final lightColors =
        light!.whereType<TextSpan>().map((s) => s.style?.color).toSet();
    final darkColors =
        dark!.whereType<TextSpan>().map((s) => s.style?.color).toSet();
    // 'final' 关键字：浅红 #D73A49 / 深粉 #F97583。
    expect(lightColors, contains(const Color(0xFFD73A49)));
    expect(darkColors, contains(const Color(0xFFF97583)));
    // "hi" 字符串：浅藏青 #032F62 / 深浅蓝 #9ECBFF。
    expect(lightColors, contains(const Color(0xFF032F62)));
    expect(darkColors, contains(const Color(0xFF9ECBFF)));
  });

  test('跳过清单与未知语言回落 null（官方 shouldUse 同款）', () {
    for (final lang in ['text', 'txt', 'plain', 'log', 'output', '', null]) {
      expect(highlightCode('abc', lang, brightness: Brightness.light), isNull,
          reason: '「$lang」应跳过');
    }
    expect(highlightCode('x', '不存在的语言', brightness: Brightness.light),
        isNull,
        reason: '语法缺失容错回落纯文本');
  });

  test('语言别名归一（js/sh/yml）', () {
    expect(highlightCode('var a = 1;', 'js', brightness: Brightness.light),
        isNotNull);
    expect(highlightCode('echo hi', 'sh', brightness: Brightness.light),
        isNotNull);
    expect(highlightCode('a: 1', 'yml', brightness: Brightness.light),
        isNotNull);
  });

  test('开关持久化往返（重启保持）', () async {
    final st = _Fs();
    final p1 = UiPrefs(storage: st);
    expect(p1.codeHighlightEnabled, isTrue, reason: '默认开');
    await p1.setCodeHighlightEnabled(false);
    final p2 = UiPrefs(storage: st);
    await p2.load();
    expect(p2.codeHighlightEnabled, isFalse, reason: '重启保持关');
    await p2.setCodeHighlightEnabled(true);
    final p3 = UiPrefs(storage: st);
    await p3.load();
    expect(p3.codeHighlightEnabled, isTrue);
  });

  testWidgets('端到端：围栏语言经 builder 缝着色渲染', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            data: '```dart\nfinal a = "x";\n```',
            codeHighlightEnabled: true,
          ),
        ),
      ),
    );
    await tester.pump();
    // 收集全部 TextSpan 颜色，块码必须出现 keyword 红（builder 拿到了
    // language-dart 属性并走到高亮路径——缝断则只有默认前景色）。
    final colors = <Color?>{};
    void walk(InlineSpan? span) {
      if (span == null) return;
      if (span is TextSpan) {
        colors.add(span.style?.color);
        span.children?.forEach(walk);
      }
    }

    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final span = t.textSpan;
      if (span is TextSpan) walk(span);
    }
    expect(colors, contains(const Color(0xFFD73A49)),
        reason: '浅色档 dart 关键字应着 github-light 红');
    // 审查 A 组回填（2026-10-23）：builder 样式必须与最终 styleSheet 同源。
    final scroll =
        tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.padding, const EdgeInsets.all(12), reason: '块码内边距=12');
    final codeText = tester.widgetList<Text>(find.byType(Text)).firstWhere(
      (t) =>
          (t.data ?? '').contains('final a') ||
          (t.textSpan is TextSpan &&
              (t.textSpan as TextSpan).toPlainText().contains('final a')),
    );
    // Text.rich 的样式挂 TextSpan 上（Text.style 为 null）。
    final span = codeText.textSpan as TextSpan?;
    expect(span?.style?.fontSize, 13, reason: '块码字号=13（uiCaption）');
    expect(span?.style?.backgroundColor, isNull, reason: '文字不得带实心底色');
    // A1 回填：尾换行剥除——渲染文本不以换行结尾（带尾换行会多一行）。
    final rendered = tester.widgetList<Text>(find.byType(Text)).first;
    expect(rendered.data, isNot(endsWith('\n')), reason: '尾换行必须剥除');
  });

  testWidgets('端到端：开关关闭=不着色（纯文本回落）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            data: '```dart\nfinal a = "x";\n```',
            codeHighlightEnabled: false,
          ),
        ),
      ),
    );
    await tester.pump();
    final colors = <Color?>{};
    void walk(InlineSpan? span) {
      if (span == null) return;
      if (span is TextSpan) {
        colors.add(span.style?.color);
        span.children?.forEach(walk);
      }
    }

    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final span = t.textSpan;
      if (span is TextSpan) walk(span);
    }
    expect(colors, isNot(contains(const Color(0xFFD73A49))),
        reason: '关掉开关不应出现关键字红');
  });

  // ── 2026-10-23 真机反馈补齐：工具行「读取」文件预览高亮 ──────────
  group('languageForFilePath（文件扩展名→高亮语言）', () {
    test('常见扩展名映射', () {
      expect(languageForFilePath('lib/ui/theme.dart'), 'dart');
      expect(languageForFilePath('src/themes.ts'), 'typescript');
      expect(languageForFilePath('app/main.tsx'), 'typescript');
      expect(languageForFilePath('tools/x.py'), 'python');
      expect(languageForFilePath('G:\path\mod.rs'), 'rust');
      expect(languageForFilePath('a.bash'), 'bash');
      expect(languageForFilePath('conf/app.json'), 'json');
      expect(languageForFilePath('conf/a.yml'), 'yaml');
    });
    test('markdown/未知扩展名/无扩展名 → null（回落纯文本）', () {
      expect(languageForFilePath('README.md'), isNull);
      expect(languageForFilePath('file.unknownext'), isNull);
      expect(languageForFilePath('noext'), isNull);
      expect(languageForFilePath(null), isNull);
      expect(languageForFilePath(''), isNull);
    });
  });
}
