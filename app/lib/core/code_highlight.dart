/// 代码块语法高亮（深色模式批 2-5 解锁实施，用户 2026-10-23 拍板：
/// 浅深两侧都对齐官方 shiki github-light/github-dark 同档 + 总开关）。
///
/// 值来源：shiki 官方主题包 @shikijs/themes@4.5.0 的 github-light/
/// github-dark（与官方桌面端 codePreviewSettings.ts 同源；调研留痕
/// 批 2-5 补记）。官方做法：shiki 只贡献 token 颜色，块底色
/// 走 app 表面色（bg 强制透明）——我们保持 codeblockDecoration=surface
/// 不变，浅色侧除 token 上色外零改动。
///
/// 引擎：`highlight`（highlight.js 9.x 语法的纯 Dart 移植，离线无平台
/// 通道，事实标准）。策略对齐官方 shikiHighlighter.ts：流式期间不高亮
/// /纯文本语言跳过/结果缓存（我们加 LRU 上限 128，官方无淘汰）。
library;

import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' as hljs;

/// hljs 类名 → 语法色（github-light / github-dark 两套）。
/// 设计扫描白名单：本文件=shiki 双主题 token 色板单源（同 theme.dart
/// 地位），字面量合法。
abstract final class AppCodeTheme {
  /// github-light（浅色档）：keyword 红/string 藏青/函数名紫/常量蓝/
  /// 变量橙/标签绿/注释灰——与官方桌面端浅色并排同款。
  static const light = <String, Color>{
    'keyword': Color(0xFFD73A49),
    'storage': Color(0xFFD73A49), // storage.type 同 keyword（shiki scope 合并）
    'literal': Color(0xFF005CC5),
    'number': Color(0xFF005CC5),
    'string': Color(0xFF032F62),
    'regexp': Color(0xFF032F62),
    'comment': Color(0xFF6A737D),
    'quote': Color(0xFF22863A),
    'doctag': Color(0xFF6A737D),
    // meta 官方无裸条目→默认前景（移除键回落 fg）。
    'title': Color(0xFF6F42C1), // 函数名/标题（entity.name）
    'function': Color(0xFF6F42C1),
    'class': Color(0xFF6F42C1), // 类型/类名（entity.name.type）
    'type': Color(0xFF6F42C1),
    'built_in': Color(0xFF005CC5), // support（语言内置）
    'attr': Color(0xFF6F42C1),
    'attribute': Color(0xFF6F42C1),
    'variable': Color(0xFFE36209),
    'template-variable': Color(0xFFE36209),
    'tag': Color(0xFF22863A), // 标签名（entity.name.tag）
    'name': Color(0xFF22863A),
    'symbol': Color(0xFF005CC5),
    'bullet': Color(0xFFE36209),
    'section': Color(0xFF005CC5),
    'selector-tag': Color(0xFF22863A),
    'selector-class': Color(0xFF6F42C1),
    'selector-id': Color(0xFF6F42C1),
    'selector-attr': Color(0xFF005CC5),
    'selector-pseudo': Color(0xFF6F42C1),
    'template-tag': Color(0xFFD73A49),
    'addition': Color(0xFF22863A),
    'deletion': Color(0xFFB31D28),
    'emphasis': Color(0xFF24292E),
    'strong': Color(0xFF24292E),
    'code': Color(0xFF24292E),
    'subst': Color(0xFF24292E),
    'operator': Color(0xFF24292E),
    'punctuation': Color(0xFF24292E),
    'char.escape': Color(0xFF032F62),
    'string.special': Color(0xFF032F62),
    'property': Color(0xFF005CC5),
  };

  /// github-dark（深色档）：同结构提亮版。
  static const dark = <String, Color>{
    'keyword': Color(0xFFF97583),
    'storage': Color(0xFFF97583),
    'literal': Color(0xFF79B8FF),
    'number': Color(0xFF79B8FF),
    'string': Color(0xFF9ECBFF),
    'regexp': Color(0xFFDBEDFF),
    'comment': Color(0xFF6A737D), // 官方两主题同灰
    'quote': Color(0xFF85E89D),
    'doctag': Color(0xFF6A737D),
    'title': Color(0xFFB392F0),
    'function': Color(0xFFB392F0),
    'class': Color(0xFFB392F0),
    'type': Color(0xFFB392F0),
    'built_in': Color(0xFF79B8FF),
    'attr': Color(0xFFB392F0),
    'attribute': Color(0xFFB392F0),
    'variable': Color(0xFFFFAB70),
    'template-variable': Color(0xFFFFAB70),
    'tag': Color(0xFF85E89D),
    'name': Color(0xFF85E89D),
    'symbol': Color(0xFF79B8FF),
    'bullet': Color(0xFFFFAB70),
    'section': Color(0xFF79B8FF),
    'selector-tag': Color(0xFF85E89D),
    'selector-class': Color(0xFFB392F0),
    'selector-id': Color(0xFFB392F0),
    'selector-attr': Color(0xFF79B8FF),
    'selector-pseudo': Color(0xFFB392F0),
    'template-tag': Color(0xFFF97583),
    'addition': Color(0xFF85E89D),
    'deletion': Color(0xFFFDAEB7),
    'emphasis': Color(0xFFE1E4E8),
    'strong': Color(0xFFE1E4E8),
    'code': Color(0xFFE1E4E8),
    'subst': Color(0xFFE1E4E8),
    'operator': Color(0xFFE1E4E8),
    'punctuation': Color(0xFFE1E4E8),
    'char.escape': Color(0xFF9ECBFF),
    'string.special': Color(0xFF9ECBFF),
    'property': Color(0xFF79B8FF),
  };

  /// 默认前景（官方：浅 #24292e / 深 #e1e4e8）。
  static const lightFg = Color(0xFF24292E);
  static const darkFg = Color(0xFFE1E4E8);
}

/// 官方同款跳过清单（shouldUseSyntaxHighlighting）：纯文本语言零收益。
const _skipLanguages = {'text', 'txt', 'plain', 'log', 'output', ''};

/// 高亮白名单（超出=未知语言回落纯文本，官方 fallback 同款语义）。
const _knownLanguages = {
  'bash', 'c', 'cpp', 'csharp', 'css', 'dart', 'diff', 'dockerfile',
  'go', 'gradle', 'groovy', 'html', 'ini', 'java', 'javascript', 'json',
  'kotlin', 'lua', 'markdown', 'objectivec', 'perl', 'php', 'powershell',
  'python', 'ruby', 'rust', 'scala', 'scss', 'shell', 'sql', 'swift',
  'toml', 'typescript', 'xml', 'yaml',
};

/// 语言别名归一（官方 languageNormalize 同思路）。
const _languageAliases = {
  'js': 'javascript',
  'ts': 'typescript',
  'py': 'python',
  'rb': 'ruby',
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'golang': 'go',
  'yml': 'yaml',
  'tsx': 'typescript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'rs': 'rust',
  'docker': 'dockerfile',
  'objective-c': 'objectivec',
  'md': 'markdown',
  'c++': 'cpp',
  'cs': 'csharp',
  'kt': 'kotlin',
  'ps1': 'powershell',
  'powershell': 'powershell',
};

/// 高亮尺寸护栏（官方同款 cap：highlighted-lightweight-diff-preview.ts:15
/// 的 120k 字符上限；服务端 conversationFileChangesV4 的
/// patches 无界，超限直接回落纯文本，防主线程同步 tokenize 秒级卡顿）。
const _maxHighlightChars = 120000;

/// 高亮结果缓存（官方无淘汰，我们加 LRU 上限防长会话内存增长）。
final _cache = <String, List<InlineSpan>>{};
const _cacheLimit = 128;

// 包级单例已注册全部语言（highlight.dart:9 allLanguages）——自建
// Highlight() 实例是零语言的（批 2-5 实施期实证踩坑）。
final hljs.Highlight _highlighter = hljs.highlight;

/// 把代码解析成着色 InlineSpan 树；返回 null=不高亮（跳过语言/解析
/// 失败/调用方禁用），调用方回落纯等宽文本。
List<InlineSpan>? highlightCode(
  String code,
  String? language, {
  required Brightness brightness,
}) {
  if (code.length > _maxHighlightChars) return null;
  final lang = _normalize(language);
  if (lang == null) return null;
  final theme =
      brightness == Brightness.dark ? AppCodeTheme.dark : AppCodeTheme.light;
  final fg = brightness == Brightness.dark
      ? AppCodeTheme.darkFg
      : AppCodeTheme.lightFg;
  final key = '$brightness|$lang|${code.length}|$code';
  final cached = _cache[key];
  if (cached != null) {
    _cache.remove(key);
    _cache[key] = cached; // LRU 触碰
    return cached;
  }
  final hljs.Result parsed;
  try {
    parsed = _highlighter.parse(code, language: lang);
  } catch (_) {
    return null; // 语法文件缺失/解析异常：回落纯文本（官方 fallback 同款）
  }
  final spans = _spansOf(parsed.nodes, theme, fg);
  if (_cache.length >= _cacheLimit) {
    _cache.remove(_cache.keys.first);
  }
  _cache[key] = spans;
  return spans;
}

String? _normalize(String? language) {
  if (language == null) return null;
  final raw = language.trim().toLowerCase();
  if (raw.isEmpty || _skipLanguages.contains(raw)) return null;
  final alias = _languageAliases[raw] ?? raw;
  return _knownLanguages.contains(alias) ? alias : null;
}

/// 文件路径 → 高亮语言（2026-10-23 用户真机反馈：工具行「读取」展开的
/// 文件预览无颜色——官方桌面端 InlineCodeContent 是带高亮的 CodeBlock
/// （ToolCallBody.tsx:131，language 来自服务端 inlinePreview 投影）；
/// 手机行数据不带该字段，按文件扩展名等价推。markdown 文件官方走
/// MessageResponse 富渲染，我们暂保持纯文本（返回 null）。
String? languageForFilePath(String? path) {
  if (path == null) return null;
  final p = path.trim().toLowerCase();
  if (!p.contains('.')) return null;
  final ext = p.substring(p.lastIndexOf('.') + 1);
  if (ext.isEmpty) return null;
  if (ext == 'md' || ext == 'markdown') return null;
  const byExt = {
    'dart': 'dart',
    'ts': 'typescript',
    'tsx': 'typescript',
    'js': 'javascript',
    'jsx': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'py': 'python',
    'rb': 'ruby',
    'rs': 'rust',
    'go': 'go',
    'java': 'java',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'c': 'c',
    'h': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'hpp': 'cpp',
    'c++': 'cpp',
    'cs': 'csharp',
    'swift': 'swift',
    'm': 'objectivec',
    'mm': 'objectivec',
    'php': 'php',
    'sql': 'sql',
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
    'json': 'json',
    'yml': 'yaml',
    'yaml': 'yaml',
    'toml': 'toml',
    'ini': 'ini',
    'cfg': 'ini',
    'css': 'css',
    'scss': 'scss',
    'html': 'html',
    'xml': 'xml',
    'gradle': 'gradle',
    'groovy': 'groovy',
    'lua': 'lua',
    'pl': 'perl',
    'ps1': 'powershell',
    'diff': 'diff',
    'patch': 'diff',
    'dockerfile': 'dockerfile',
  };
  final lang = byExt[ext];
  if (lang == null) return null;
  return _knownLanguages.contains(lang) ? lang : null;
}

/// 递归展开：hljs 的文本在子节点（value=null 的 span 节点包着
/// value=文本 的子节点），着色类名取最近的非空祖先 className——
/// 初版丢了父类名上下文（全渲染默认前景，实施期实证踩坑）。
List<InlineSpan> _spansOf(
  List<hljs.Node>? nodes,
  Map<String, Color> theme,
  Color fg, {
  String? inheritedClass,
}) {
  if (nodes == null) return [];
  return [
    for (final node in nodes)
      if (node.value != null)
        TextSpan(
          text: node.value,
          style: TextStyle(
            color: _colorOf(
              node.className ?? inheritedClass,
              theme,
              fg,
            ),
          ),
        )
      else
        ..._spansOf(
          node.children,
          theme,
          fg,
          inheritedClass: node.className ?? inheritedClass,
        ),
  ];
}

/// hljs 类名可能是复合（空格分隔的 scope 链，如 "title function_"），
/// 从链尾向前找第一个命中主题表的类。
Color _colorOf(String? className, Map<String, Color> theme, Color fg) {
  if (className == null) return fg;
  for (final part in className.split(' ')) {
    final c = theme[part];
    if (c != null) return c;
    // "title.function_" 形态：按 . 拆细粒度 scope。
    for (final sub in part.split('.')) {
      final c2 = theme[sub];
      if (c2 != null) return c2;
    }
  }
  return fg;
}

/// 测试缝：清缓存。
void debugClearHighlightCache() {
  _cache.clear();
  _linesCache.clear();
}

/// diff 行分类（unified diff marker 语义）。
enum DiffLineKind { add, del, context, hunk }

/// 一行 diff 的着色视图：[text]=剥掉 +/-/空格 marker 的代码内容
/// （hunk 行=原始 @@ 行），[spans]=语法 token 着色（语言未知/解析失败
/// 为 null，调用方回落纯色呈现）。
class DiffLineView {
  final DiffLineKind kind;
  final String text;
  final List<InlineSpan>? spans;
  const DiffLineView(this.kind, this.text, this.spans);
}

/// 按行切分缓存（diff 视图用，与 [_cache] 分池）。
final _linesCache = <String, List<List<InlineSpan>>>{};

/// 整文一次 tokenize 后按 \n 切回逐行 spans——跨行 token（块注释/
/// 多行字符串）不断色的唯一做法（不能逐行单独 tokenize；官方
/// highlighted-lightweight-diff-preview.ts:140-159 同款）。返回 null=
/// 不高亮（跳过语言/解析失败），第 i 项=第 i 行。
List<List<InlineSpan>>? highlightCodeLines(
  String code,
  String? language, {
  required Brightness brightness,
}) {
  if (code.length > _maxHighlightChars) return null;
  final lang = _normalize(language);
  if (lang == null) return null;
  final theme =
      brightness == Brightness.dark ? AppCodeTheme.dark : AppCodeTheme.light;
  final fg = brightness == Brightness.dark
      ? AppCodeTheme.darkFg
      : AppCodeTheme.lightFg;
  final key = '$brightness|$lang|${code.length}|$code';
  final cached = _linesCache[key];
  if (cached != null) {
    _linesCache.remove(key);
    _linesCache[key] = cached; // LRU 触碰
    return cached;
  }
  final hljs.Result parsed;
  try {
    parsed = _highlighter.parse(code, language: lang);
  } catch (_) {
    return null;
  }
  final lines = <List<InlineSpan>>[<InlineSpan>[]];
  void emit(String text, Color color) {
    var rest = text;
    while (true) {
      final nl = rest.indexOf('\n');
      if (nl < 0) {
        if (rest.isNotEmpty) {
          lines.last.add(
            TextSpan(text: rest, style: TextStyle(color: color)),
          );
        }
        return;
      }
      if (nl > 0) {
        lines.last.add(
          TextSpan(text: rest.substring(0, nl), style: TextStyle(color: color)),
        );
      }
      lines.add(<InlineSpan>[]);
      rest = rest.substring(nl + 1);
    }
  }

  void walk(List<hljs.Node>? nodes, String? inheritedClass) {
    if (nodes == null) return;
    for (final node in nodes) {
      if (node.value != null) {
        emit(
          node.value!,
          _colorOf(node.className ?? inheritedClass, theme, fg),
        );
      } else {
        walk(node.children, node.className ?? inheritedClass);
      }
    }
  }

  walk(parsed.nodes, null);
  if (_linesCache.length >= _cacheLimit) {
    _linesCache.remove(_linesCache.keys.first);
  }
  _linesCache[key] = lines;
  return lines;
}

/// 对一个 hunk 的 unified diff lines 整体语法着色（按 hunk 粒度调用
/// ——跨 hunk 的文件内容本就断开）。官方 diff 三处表面（富 DiffViewer/
/// 变更总结预览/聊天内联 diff）全部带 shiki 高亮（2026-10-23 真机
/// 反馈"变更代码没有颜色"的对位修复）；marker 剥离语义对齐
/// lightweight-diff-preview.ts:37-71——+/-/空格 是协议 marker 不是代码
/// 内容，增删由底色+行首竖条表达（官方 diffIndicators 同思路）。
List<DiffLineView> highlightDiffLines(
  List<String> lines,
  String? language, {
  required Brightness brightness,
}) {
  final codeLines = <String>[];
  final kinds = <DiffLineKind>[];
  // CRLF 尾剥：上游 jsdiff 每块只剥 \n，CRLF 文件的行
  // 尾 \r 存活进 span 且等宽渲染占一格宽（豆腐块）——Flutter 不像
  // HTML 解析器那样归一化 CR，须自剥。
  String strip(dynamic rawLine) => '$rawLine'.replaceFirst(RegExp(r'\r$'), '');
  for (final raw in lines) {
    final line = strip(raw);
    if (line.startsWith('@@')) {
      kinds.add(DiffLineKind.hunk);
      codeLines.add(''); // 占位保行号对齐（hunk 行内容不参与 tokenize）
      continue;
    }
    if (line.startsWith('+')) {
      kinds.add(DiffLineKind.add);
      codeLines.add(line.substring(1));
    } else if (line.startsWith('-')) {
      kinds.add(DiffLineKind.del);
      codeLines.add(line.substring(1));
    } else {
      kinds.add(DiffLineKind.context);
      codeLines.add(
        line.isNotEmpty && line.startsWith(' ') ? line.substring(1) : line,
      );
    }
  }
  final spans = highlightCodeLines(
    codeLines.join('\n'),
    language,
    brightness: brightness,
  );
  return [
    for (var i = 0; i < lines.length; i++)
      DiffLineView(
        kinds[i],
        kinds[i] == DiffLineKind.hunk ? strip(lines[i]) : codeLines[i],
        spans == null || i >= spans.length ? null : spans[i],
      ),
  ];
}
