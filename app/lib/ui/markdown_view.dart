import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../core/code_highlight.dart';
import '../core/theme.dart';
import 'app_widgets.dart';

/// 本地路径链接预处理（早期反馈②b）：agent 回复常带
/// `[文件名](G:\path with space\文件.txt)`——路径含空格/反斜杠不是
/// 合法 CommonMark 目标，渲染器会原样输出。预处理把本地路径
/// 百分号编码成可解析链接，再由 a: 样式渲染为绿色文件名（桌面观感）。
final _localLinkRe = RegExp(
  r'\[([^\]\n]+)\]\(([A-Za-z]:\\[^)\n]*|/[^\s)][^)\n]*)\)',
);

String _encodeSegment(String s) => s.replaceAllMapped(_localLinkRe, (m) {
      final label = m.group(1)!;
      final path = m.group(2)!;
      // 契约：href 为百分号编码形态（含 %5C 反斜杠），解码在 onTapLink。
      return '[$label](${Uri.encodeFull(path)})';
    });

String _encodeLocalLinks(String data) {
  // 围栏代码块与行内码内的路径不做改写（内容保真）。
  final blocks = data.split('```');
  final out = <String>[];
  for (var i = 0; i < blocks.length; i++) {
    if (i.isOdd) {
      out.add(blocks[i]);
      continue;
    }
    final spans = blocks[i].split('`');
    final seg = <String>[];
    for (var j = 0; j < spans.length; j++) {
      seg.add(j.isEven ? _encodeSegment(spans[j]) : spans[j]);
    }
    out.add(seg.join('`'));
  }
  return out.join('```');
}

/// 助手消息 markdown 渲染（阶段 1：基础排版；2026-11-04 换 flutter_markdown_plus）+
/// 代码语法高亮（批 2-5 解锁，2026-10-23 用户拍板：浅深两侧对齐官方
/// shiki github 同档+总开关；流式期间不高亮=官方策略）。
class MarkdownView extends StatelessWidget {
  final String data;
  final bool streaming;

  /// 语法高亮总开关（设置→对话；默认开）。由调用方从 uiPrefs 传入。
  final bool codeHighlightEnabled;

  const MarkdownView({
    super.key,
    required this.data,
    this.streaming = false,
    this.codeHighlightEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    final brightness = Theme.of(context).brightness;
    // 审查 A 组修复（2026-10-23）：pre 构建器接管了全部块码渲染，其
    // 样式/内边距必须与 copyWith 后的最终 styleSheet 同源——原先传
    // fromTheme 出厂值（padding 8/字号 11.9/文字实心底色），与包默认
    // 路径消费的最终值（12/13/无底色）四项不一致=视觉回归。故先把
    // 最终表算出来，builders 与 styleSheet: 两处共用。
    final styleSheet = _buildStyleSheet(context, base);
    // 块码语言预提取：markdown 包把 ```lang 放进 code 元素 attributes，
    // 但块码构建走 'pre' 的 visitText 路径拿不到 attributes（builder.dart
    // :405-409 实证）——从原文把「代码文本→语言」先抽成表，pre 构建器
    // 按文本反查（同内容多块同语言，键不敏感）。禁用/流式时跳过全文
    // 正则扫描（审查 B：流式期间 O(n²)/帧纯浪费）。
    final highlightOn = codeHighlightEnabled && !streaming;
    final languages = highlightOn ? _fenceLanguages(data) : const <String, String>{};
    return L10nScope(
      enabled: false,
      child: MarkdownBody(
      data: _encodeLocalLinks(streaming ? '$data ▍' : data),
      builders: {
        'pre': _PreHighlightBuilder(
          brightness: brightness,
          enabled: highlightOn,
          baseStyle: styleSheet.code ?? const TextStyle(fontFamily: 'monospace'),
          languages: languages,
          padding: styleSheet.codeblockPadding ?? const EdgeInsets.all(12),
        ),
      },
      // 点链接的响应分两类（批4 反馈④，2026-10-23 用户拍板）：
      // - 本地文件路径：协议层无文件内容读取 RPC（ZCode 官方开源实现
      //   zcode-protocol-v4 全量 grep 实证，桌面预览是本地读盘），复制
      //   路径在手机端无实用价值——点击不做任何响应（绿色渲染保留）。
      // - 网络链接：保持可点（提示+复制）。
      onTapLink: (text, href, title) {
        if (href == null || href.isEmpty) return;
        // 非 ASCII/非法 %xx 会让 decodeFull 抛 ArgumentError——
        // 守卫解码，失败用原样。
        String decoded;
        try {
          decoded = Uri.decodeFull(href);
        } catch (_) {
          decoded = href;
        }
        final isLocal =
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(decoded) ||
                decoded.startsWith('/');
        if (isLocal) return;
        Clipboard.setData(ClipboardData(text: decoded));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('链接：$decoded'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      styleSheet: styleSheet,
      ),
    );
  }

  /// 最终样式表（审查 A 组修复抽出）：builders 与 styleSheet 共用同一
  /// 实例，防两处取值漂移。
  MarkdownStyleSheet _buildStyleSheet(
    BuildContext context,
    MarkdownStyleSheet base,
  ) =>
      base.copyWith(
// 排版密度对齐官方。
        p: TextStyle(
          fontSize: AppType.uiBase,
          color: context.colors.foreground,
          // 验收回填（2026-10-22 三档反馈）：1.6 太紧/1.75 稍松 → 1.7。
          height: 1.7,
          letterSpacing: 0.2,
        ),
        listBullet: TextStyle(
          fontSize: AppType.uiBase,
          // 官方 marker:text-foreground-subtlest（markdown-list.tsx:20,43）
          // ——序号/bullet 比正文退一档，不再同浓。
          color: context.colors.foregroundSubtlest,
          height: 1.7,
        ),
        // 标题分节呼吸感：官方 h1=18/h2=16/h3=14 且统一 mt-6 mb-4
        // （message.tsx:441-446）——此前零边距挤成一块。
        h1: const TextStyle(
          fontSize: AppType.uiXl,
          fontWeight: FontWeight.w600,
        ),
        h2: const TextStyle(
          fontSize: AppType.uiLg,
          fontWeight: FontWeight.w600,
        ),
        h3: const TextStyle(
          fontSize: AppType.uiBase,
          fontWeight: FontWeight.w600,
        ),
        h1Padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
        h2Padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
        h3Padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
        blockSpacing: 12,
        // 引用块对齐官方（markdown-blockquote.tsx:14）：无底色无圆角，
        // 2px 左线+左 12 缩进+subtle 文字——此前 surface 底卡观感。
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: context.colors.border, width: 2)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: AppType.uiCaption,
          color: context.colors.foreground,
        ),
        // 代码块圆角对齐官方 rounded-xl(12)（code-block.tsx:155）。
        codeblockDecoration: BoxDecoration(
          color: context.colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.block),
          border: Border.all(color: context.colors.border),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        tableBorder: TableBorder.all(
          color: context.colors.border,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        tableCellsDecoration: BoxDecoration(color: context.colors.card),
        // flutter_markdown_plus（2026-11-04 换包）新增表头单元格装饰，
        // 且默认回退 tableCellsDecoration——表头会被染成 card 底色，
        // 与旧包"表头透明、仅偶数数据行着色"的既有观感不一致。依赖替换
        // 不应夹带设计变更：显式透明把表头钉回旧观感（A/B 像素差归零）。
        tableHeadCellsDecoration: const BoxDecoration(),
        // 表格手机端优化（2026-10-20 用户反馈"表格没针对手机优化"）：
        // 默认 FlexColumnWidth 把列硬塞进屏宽=与桌面同款挤压；改
        // IntrinsicColumnWidth（列宽随内容）后渲染器自动
        // 包横向 SingleChildScrollView+Scrollbar——宽表滚动看，窄表原样。
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 6,
        ),
        blockquote: TextStyle(
          fontSize: AppType.uiBase,
          color: context.colors.foregroundSubtle,
          height: 1.7,
        ),
        // ②b：文件链接=绿色文件名（无下划线，桌面观感）。
        a: TextStyle(
          fontSize: AppType.uiBase,
          color: context.colors.success,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w500,
        ),
      );
}

/// 原文围栏语言提取：```lang\n...\n``` → {代码文本.trim(): lang}。
Map<String, String> _fenceLanguages(String data) {
  final map = <String, String>{};
  final re = RegExp(
    '^```([A-Za-z0-9+#._-]*)[^\\n]*\\n(.*?)^```',
    multiLine: true,
    dotAll: true,
  );
  for (final m in re.allMatches(data)) {
    final lang = m.group(1) ?? '';
    final code = m.group(2) ?? '';
    if (lang.isNotEmpty) map[code.trim()] = lang;
  }
  return map;
}

/// pre 块构建器：visitText 拿到围栏内原始文本，按预提取表反查语言着色；
/// 查不到/禁用/跳过语言一律返回 null 走包默认渲染（横向滚动+底色壳
/// 均为包内行为）。着色分支自建横向滚动（包的 _ScrollControllerBuilder
/// 不外露），底色/描边壳由包的 codeblockDecoration 外层照常提供。
class _PreHighlightBuilder extends MarkdownElementBuilder {
  _PreHighlightBuilder({
    required this.brightness,
    required this.enabled,
    required this.baseStyle,
    required this.languages,
    required this.padding,
  });

  final Brightness brightness;
  final bool enabled;
  final TextStyle baseStyle;
  final Map<String, String> languages;
  final EdgeInsets padding;

  @override
  Widget? visitText(md.Text text, TextStyle? style) {
    // 块级 builder 不允许返回 null（包内 _inlines.isEmpty 断言，禁用
    // 路径实证踩坑）——不高亮时自兜底复刻默认渲染（横向滚动+滚动条+
    // padding+mono 文本），保证关闭开关后与旧纯文本观感一致。
    // 审查 （双员交叉命中）：包默认 formatText 会剥一个尾换行
    // （widget.dart:454-459），自定义路径原样渲染=每块多一行空行——
    // 高亮/纯文本两路都先剥（与缓存 key 一致性由 trim 保证）。
    var source = text.text;
    while (source.endsWith('\n') || source.endsWith('\r')) {
      source = source.substring(0, source.length - 1);
    }
    final language = enabled ? languages[source.trim()] : null;
    final spans =
        language != null ? highlightCode(source, language, brightness: brightness) : null;
    // 2026-10-23 用户反馈批⑧：代码块右上角一键复制（官方
    // CodeBlockCopyButton code-block.tsx:454 对位，复制代码原文非渲染
    // 文本）。按钮浮在横向滚动壳之上，不随代码横向滚动。
    return Stack(
      children: [
        _PreScroll(
          padding: padding,
          child: spans != null
              ? Text.rich(
                  TextSpan(style: baseStyle, children: spans),
                  softWrap: false,
                )
              : Text(
                  source,
                  style: baseStyle,
                  softWrap: false,
                ),
        ),
        Positioned(
          top: 0,
          right: 0,
          // 优化批 #5：复制键左侧加语言标签（等宽小号；语言表只在
          // 高亮开启时预提取，禁用/流式态不显示——与高亮同开关）。
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (language != null)
                Builder(
                  builder: (context) => Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Text(
                      language,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: context.colors.foregroundSubtlest,
                      ),
                    ),
                  ),
                ),
              CopyIconButton(
                text: source,
                tooltip: tr('复制代码'),
                snackText: '代码已复制',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 包内默认 pre 的滚动壳复刻（_ScrollControllerBuilder 私有不可复用；
/// 独立 controller 视觉等价——共享 controller 只是包的多块优化）。
class _PreScroll extends StatefulWidget {
  const _PreScroll({required this.padding, required this.child});

  final EdgeInsets padding;
  final Widget child;

  @override
  State<_PreScroll> createState() => _PreScrollState();
}

class _PreScrollState extends State<_PreScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}
