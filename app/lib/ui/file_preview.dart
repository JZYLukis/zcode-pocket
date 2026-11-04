import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:webview_flutter/webview_flutter.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';

/// 生成文件预览·网页档（file-preview-1，2026-10-29 用户拍板「只做 html
/// 的部分」）：官方协议无任意文件字节读取通道（zcode-protocol-v4
/// V4_METHODS 全量核实；官方 web 远程同样抑制 html 预览卡，见
/// assistantPreviewCards.ts:311「Web 远控没有本地端口转发或 HTML 运行
/// 环境」）。唯一原生可达路径：**新建 html 文件的全文随 fileChanges 到
/// 达**（新文件 diff=全量行）——本地 WebView 渲染，零提示词零额度。
/// 图片/PDF 档经用户拍板不做（取回变通消耗额度，留待官方通道）。

// ------------------------------------------------------------ 纯函数

final _htmlExtRe = RegExp(r'\.(html?|xhtml)$', caseSensitive: false);

bool isRenderableHtmlPath(String path) => _htmlExtRe.hasMatch(path.trim());

/// 把 fileChanges 的只读 hunk 拼成「新建文件全文」：仅当全部行都是新增
/// 行（本轮新建/整文件重写）时成立；出现删除行（编辑）或无行 → null
/// （协议只送变更片段，宁进 diff 也不渲染半份内容冒充全文）。
String? assembleNewFileText(List<Map<String, dynamic>> patches) {
  final lines = <String>[];
  for (final patch in patches) {
    final raw = patch['lines'];
    if (raw is! List) return null;
    for (final line in raw) {
      if (line is! String) return null;
      // 官方 jsdiff 默认 4 行上下文——纯插入编辑
      // 无删除行但含上下文行，旧判据会当全文渲染成拼盘；收紧为逐行
      // 必须 `+` 前缀（上下文/删除一律 null）。
      // C2：jsdiff 无尾换行标记行（`\ No newline at end of file`，
      // 官方夹具 file-tool-port.test.ts:688 实证随 lines 真实到达）不是
      // 内容——跳过而非整体放弃（无尾换行的新建 html 也要能预览）。
      if (line.startsWith(r'\')) continue;
      if (!line.startsWith('+')) return null;
      lines.add(line.substring(1));
    }
  }
  if (lines.isEmpty) return null;
  return lines.join('\n');
}

// ------------------------------------------------------------ ::visualize 指令

/// 18074 验收③：agent 用可视化工具时回复正文携带 `::visualize{"path":…}`
/// 指令（官方 gen-ui 引用语法，references.test.ts 实证；桌面端投影成
/// 沙箱页面，手机端此前显示为原始指令串=用户实锤「一大串代码串」）。
/// 手机消费=指令位渲染成可点卡片，点按经本轮 fileChanges 解析路径取
/// 全文进渲染页；取不到诚实降级。宽容 `::visualizer` 变体（agent 常见
/// 手误，官方当纯文本——手机做成卡片是纯显示层裁量，涉协议行为不变）。
final visualizeDirectiveRe = RegExp(
  r'::visualizer?\{"path"\s*:\s*"([^"]+)"[^}]*\}',
);

/// 正文 → [文本段 | 指令段] 序列（无指令=单文本段，调用方零开销路径）。
class VisualizeSegment {
  const VisualizeSegment.text(this.text) : path = null;
  const VisualizeSegment.directive(this.path) : text = null;
  final String? text;
  final String? path;
}

List<VisualizeSegment> parseVisualizeSegments(String text) {
  final out = <VisualizeSegment>[];
  var start = 0;
  for (final m in visualizeDirectiveRe.allMatches(text)) {
    if (m.start > start) {
      out.add(VisualizeSegment.text(text.substring(start, m.start)));
    }
    out.add(VisualizeSegment.directive(m.group(1)!));
    start = m.end;
  }
  if (out.isEmpty) return [VisualizeSegment.text(text)];
  if (start < text.length) out.add(VisualizeSegment.text(text.substring(start)));
  return out;
}

String _normFsPath(String p) =>
    p.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/').toLowerCase();

/// 指令路径（常为绝对路径）与 fileChanges 条目路径（工作区相对/绝对
/// 形态不定）按尾部段匹配（双向 tail），两侧形态差异不敏感。
/// C1/C2：只允许带 `/` 段边界的尾部匹配——裸 endsWith 会让
/// `preindex.html` 命中 `index.html` 打开错误文件。
bool visualizePathMatches(String directivePath, String itemPath) {
  final a = _normFsPath(directivePath);
  final b = _normFsPath(itemPath);
  if (a == b) return true;
  return a.endsWith('/$b') || b.endsWith('/$a');
}

/// 指令位的可点卡片：点按 → 本轮 fileChanges 找同路径条目 → 全文进
/// HtmlPreviewPage；找不到/非新建 → 人话提示。
class VisualizeCard extends StatefulWidget {
  const VisualizeCard({
    super.key,
    required this.path,
    this.sessionId,
    this.header,
  });

  final String path;
  final String? sessionId;

  /// 所属轮的 turnHeader 行（rowId+entityId，fileChanges target）。
  final Map<String, dynamic>? header;

  @override
  State<VisualizeCard> createState() => _VisualizeCardState();
}

class _VisualizeCardState extends State<VisualizeCard> {
  bool _busy = false;

  Future<void> _open() async {
    if (_busy) return;
    final sessionId = widget.sessionId;
    final header = widget.header;
    final entityId = '${header?['entityId'] ?? ''}'.trim();
    if (sessionId == null || header == null || entityId.isEmpty) {
      _snack('未能定位该可视化所属的轮次');
      return;
    }
    setState(() => _busy = true);
    try {
      final app = AppStateScope.of(context);
      final res = await app.fileChanges(sessionId, target: {
        'rowId': header['rowId'],
        'entityId': entityId,
      });
      final items = (res is Map ? res['items'] as List? : null) ?? const [];
      Map<String, dynamic>? hit;
      for (final e in items) {
        if (e is Map && visualizePathMatches(widget.path, '${e['path']}')) {
          hit = e.cast<String, dynamic>();
          break;
        }
      }
      final patches = (hit?['patches'] as List?)
              ?.whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList() ??
          const <Map<String, dynamic>>[];
      final full = hit == null ? null : assembleNewFileText(patches);
      if (!mounted) return;
      if (full == null) {
        _snack(
          hit == null
              ? '该可视化文件不在本轮文件变更里，手机暂无法读取（桌面端可直接查看）'
              : '该文件非本轮新建（只送变更片段），暂无法渲染',
        );
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HtmlPreviewPage(
            title: widget.path.split(RegExp(r'[\\/]')).last,
            htmlContent: full,
          ),
        ),
      );
    } catch (e) {
      if (mounted) _snack('读取失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(text)), duration: const Duration(seconds: 3)),
      );

  @override
  Widget build(BuildContext context) {
    final leaf = widget.path.split(RegExp(r'[\\/]')).last;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          key: ValueKey('visualize-card-${widget.path}'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: _busy
                      ? const CircularProgressIndicator(strokeWidth: 1.6)
                      : Icon(
                          Icons.insights_outlined,
                          size: 16,
                          color: context.colors.brandAccent,
                        ),
                ),
                const SizedBox(width: 8),
                Text(
                  tr('可视化'),
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    leaf,
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppType.uiCaption,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: context.colors.foregroundSubtlest,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ 网页预览页

/// 新建 html 文件的本地渲染页。
///
/// 导航纪律：内容来自 agent 生成的单文件 html，本地 loadHtmlString；
/// 页面自身引用的 http(s) 子资源（CDN 库）放行加载，但**任何导航跳转一
/// 律拦截**（渲染页不是浏览入口，连官方域也不放行——比 web_fallback 的
/// 官方域白名单更严）。多文件站点引用的本地 css/js/图片协议拿不到，
/// 只有单文件页面能完整渲染。
/// ：预览页 CSP——agent/artifact 生成的 html 在
/// unrestricted JS 下可 fetch/XHR 外发任意域（导航拦不住子资源请求）。
/// connect-src 'none' 关死外发回传；脚本/样式/图片放行 https CDN（官方
/// visualize 页同款资源域面）。
String injectPreviewCsp(String html) {
  // 单引号用 ' 规避 Dart 字符串转义噪音；策略与官方 visualize 资源
  // 域一致（https CDN 放行、外发连接关死）。
  const csp = "default-src 'none'; script-src 'unsafe-inline' https:; "
      "style-src 'unsafe-inline' https:; img-src https: data:; "
      "media-src https:; font-src https:; connect-src 'none'";
  final meta = '<meta http-equiv="Content-Security-Policy" content="$csp">';
  // C1/C2：旧 indexOf('<head') 会被 `<header>` 标签或含 `<head>` 的
  // 注释劫持——meta 落进 body/注释时 Chromium 直接忽略，connect-src
  // 'none' 防线整页静默失效。改为正则精确定位真 `<head>`/`<head …>`
  // 开标签（`<header` 的下一个字符是 e，不匹配 \s|>；大小写不敏感），
  // 且跳过注释内的假命中。
  final comments = _htmlCommentRe
      .allMatches(html)
      .map((m) => (m.start, m.end))
      .toList(growable: false);
  for (final m in _headOpenRe.allMatches(html)) {
    final inComment = comments.any((c) => m.start >= c.$1 && m.start < c.$2);
    if (inComment) continue;
    return html.replaceRange(m.end, m.end, meta);
  }
  // 无 head：前置 meta 到 doctype 之前会触发 quirks 模式（盒模型/行高
  // 整体漂移）——包一层完整 html 骨架，meta 落在骨架 head 内。
  return '<!DOCTYPE html><html><head>$meta</head><body>$html</body></html>';
}

final _htmlCommentRe = RegExp(r'<!--[\s\S]*?-->');
final _headOpenRe = RegExp(r'<head(?:\s[^>]*)?>', caseSensitive: false);

bool isHtmlPreviewNavAllowed(Uri? uri) {
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'about' || scheme == 'data' || scheme == 'blob';
}

class HtmlPreviewPage extends StatefulWidget {
  final String title;
  final String htmlContent;

  /// 测试缝：无 WebView 平台通道的环境（widget 测试）禁用控制器创建。
  @visibleForTesting
  static bool debugDisableWebView = false;

  const HtmlPreviewPage({
    super.key,
    required this.title,
    required this.htmlContent,
  });

  @override
  State<HtmlPreviewPage> createState() => _HtmlPreviewPageState();
}

class _HtmlPreviewPageState extends State<HtmlPreviewPage> {
  WebViewController? _controller;
  String? _loadError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null || HtmlPreviewPage.debugDisableWebView) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 18076 反馈#9：文档查看器约定白底（documentPaper 双主题同值白）
      // ——深色主题下此前用主题背景色，透明生成页面整体蒙黑。
      ..setBackgroundColor(context.colors.documentPaper)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final allowed = isHtmlPreviewNavAllowed(Uri.tryParse(req.url));
            return allowed
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame == true && mounted) {
              setState(() => _loadError = '${e.errorCode}: ${e.description}');
            }
          },
        ),
      );
    _controller = controller;
    unawaited(
      controller
          .loadHtmlString(injectPreviewCsp(widget.htmlContent))
          .catchError((Object e) {
        if (mounted) setState(() => _loadError = '$e');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.title, translate: false, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: controller == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr('网页组件不可用：$_loadError'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.colors.foregroundSubtle),
                ),
              ),
            )
          : Stack(
              children: [
                WebViewWidget(controller: controller),
                if (_loadError != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: context.colors.card,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: context.colors.border),
                      ),
                      child: Text(
                        tr('渲染失败：$_loadError'),
                        style: TextStyle(
                          fontSize: 12,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
