import 'dart:math' as math show min;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';

/// 截图圈点标注（阶段 6.6④，ADR 0062）：发送前在图片上手绘圈画。
///
/// 交互（对标系统截图标注的最小集）：手指自由画线、4 色画笔、撤销
/// 上一笔、清空、保存（pop 带回合成 PNG 全分辨率字节；取消 pop 空值）。
/// 保存后由会话页替换附件字节并作废旧上传引用（重新上传）。
class AnnotateStroke {
  final Color color;
  final double width;
  final List<Offset> points;

  const AnnotateStroke({
    required this.color,
    required this.width,
    required this.points,
  });
}

class AttachmentAnnotatePage extends StatefulWidget {
  final Uint8List imageBytes;
  final String fileName;

  /// 游览/测试缝：预置笔迹与预解码底图（确定性截图/保存往返用；
  /// 生产均 null——真实路径走 instantiateImageCodec 解码）。
  @visibleForTesting
  static List<AnnotateStroke>? debugInitialStrokes;

  @visibleForTesting
  static ui.Image? debugImage;

  const AttachmentAnnotatePage({
    super.key,
    required this.imageBytes,
    required this.fileName,
  });

  @override
  State<AttachmentAnnotatePage> createState() => _AttachmentAnnotatePageState();
}

class _AttachmentAnnotatePageState extends State<AttachmentAnnotatePage> {
  ui.Image? _image;
  String? _error;
  final List<AnnotateStroke> _strokes = [];
  late List<Color> _palette;
  late Color _color;
  AnnotateStroke? _current;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 色板引用主题 token（设计守卫单源；红=圈重点默认）——
    // initState 不能读 ThemeExtension（依赖未建立），随依赖初始化。
    if (!_paletteReady) {
      _paletteReady = true;
      _palette = [
        context.colors.destructive,
        context.colors.linkBlue,
        context.colors.warning,
        context.colors.foreground,
      ];
      _color = _palette.first;
    }
  }

  bool _paletteReady = false;

  @override
  void initState() {
    super.initState();
    final preset = AttachmentAnnotatePage.debugInitialStrokes;
    if (preset != null) _strokes.addAll(preset);
    final presetImage = AttachmentAnnotatePage.debugImage;
    if (presetImage != null) {
      _image = presetImage;
    } else {
      _decode();
    }
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _image = frame.image);
    } on Object {
      if (mounted) {
        setState(() => _error = '图片解码失败，无法标注');
      }
    }
  }

  void _onPanStart(Offset position) {
    setState(() {
      _current = AnnotateStroke(color: _color, width: 3, points: [position]);
    });
  }

  void _onPanUpdate(Offset position) {
    final stroke = _current;
    if (stroke == null) return;
    setState(
      () => _current = AnnotateStroke(
        color: stroke.color,
        width: stroke.width,
        points: [...stroke.points, position],
      ),
    );
  }

  void _onPanEnd() {
    final stroke = _current;
    if (stroke == null) return;
    if (stroke.points.length < 2) {
      // 单点=点一下：落一个最小墨点（两点重合）而非吞掉。
      setState(() {
        _strokes.add(
          AnnotateStroke(
            color: stroke.color,
            width: stroke.width,
            points: [stroke.points.first, stroke.points.first],
          ),
        );
        _current = null;
      });
      return;
    }
    setState(() {
      _strokes.add(stroke);
      _current = null;
    });
  }

  Future<void> _save() async {
    final image = _image;
    if (image == null || _strokes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    // 显示坐标系 → 原图像素坐标（布局矩形在 build 里缓存）。
    final rect = _displayRect;
    if (rect == null) return;
    final edited = await renderAnnotatedImage(
      image: image,
      strokes: _strokes,
      displayToImageScale: image.width / rect.width,
    );
    if (!mounted || edited == null) return;
    Navigator.of(context).pop(edited);
  }

  Rect? _displayRect;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(
        title: const Text('标注图片'),
        actions: [
          IconButton(
            key: const ValueKey('annotate-undo'),
            tooltip: tr('撤销'),
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() => _strokes.removeLast()),
            icon: const Icon(Icons.undo, size: 20),
          ),
          IconButton(
            key: const ValueKey('annotate-clear'),
            tooltip: tr('清空'),
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(() => _strokes.clear()),
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  // 画布常驻（解码完成前以占位区呈现——测试环境解码走
                  // 真实异步不回包，画布不得依赖解码完成才挂载）。
                  child: LayoutBuilder(
                    builder: (context, cons) {
                      final img = image;
                      late final Rect rect;
                      if (img != null) {
                        final scale = math.min(
                          cons.maxWidth / img.width,
                          cons.maxHeight / img.height,
                        );
                        final w = img.width * scale;
                        final h = img.height * scale;
                        rect = Rect.fromLTWH(
                          (cons.maxWidth - w) / 2,
                          (cons.maxHeight - h) / 2,
                          w,
                          h,
                        );
                      } else {
                        rect = Rect.fromLTWH(
                          0,
                          0,
                          cons.maxWidth,
                          cons.maxHeight,
                        );
                      }
                      _displayRect = rect;
                      return GestureDetector(
                        onPanStart: img == null
                            ? null
                            : (d) =>
                                  _onPanStart(d.localPosition - rect.topLeft),
                        onPanUpdate: img == null
                            ? null
                            : (d) =>
                                  _onPanUpdate(d.localPosition - rect.topLeft),
                        onPanEnd: img == null ? null : (_) => _onPanEnd(),
                        child: CustomPaint(
                          key: const ValueKey('annotate-canvas'),
                          size: Size.infinite,
                          painter: _AnnotatePainter(
                            image: img,
                            displayRect: rect,
                            placeholderColor: context.colors.sidebar,
                            strokes: [
                              ..._strokes,
                              if (_current != null) _current!,
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // 画笔色板（选中描边环）+保存。
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                    child: Row(
                      children: [
                        for (var i = 0; i < _palette.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: GestureDetector(
                              key: ValueKey('annotate-color-$i'),
                              onTap: () => setState(() => _color = _palette[i]),
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: _palette[i],
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _color == _palette[i]
                                        ? context.colors.foreground
                                        : Colors.transparent,
                                    width: 2.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const Spacer(),
                        FilledButton(
                          key: const ValueKey('annotate-save'),
                          onPressed: _saving
                              ? null
                              : () async {
                                  setState(() => _saving = true);
                                  await _save();
                                  if (mounted) {
                                    setState(() => _saving = false);
                                  }
                                },
                          child: Text(tr('保存')),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 合成原图+笔迹（全分辨率）：笔迹坐标为图像显示区局部坐标，
/// displayToImageScale=图像像素宽/显示宽（等比）。
@visibleForTesting
Future<Uint8List?> renderAnnotatedImage({
  required ui.Image image,
  required List<AnnotateStroke> strokes,
  required double displayToImageScale,
}) async {
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Paint(),
    );
    final s = displayToImageScale;
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          Offset(stroke.points.first.dx * s, stroke.points.first.dy * s),
          stroke.width * s / 2,
          Paint()..color = stroke.color,
        );
        continue;
      }
      final paint = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.width * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()
        ..moveTo(stroke.points.first.dx * s, stroke.points.first.dy * s);
      for (final p in stroke.points.skip(1)) {
        path.lineTo(p.dx * s, p.dy * s);
      }
      canvas.drawPath(path, paint);
    }
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(image.width, image.height);
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    return data == null ? null : data.buffer.asUint8List();
  } on Object {
    return null;
  }
}

class _AnnotatePainter extends CustomPainter {
  final ui.Image? image;
  final Rect displayRect;
  final List<AnnotateStroke> strokes;
  final Color placeholderColor;

  _AnnotatePainter({
    required this.image,
    required this.displayRect,
    required this.strokes,
    required this.placeholderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(displayRect);
    if (image != null) {
      paintImage(
        canvas: canvas,
        rect: displayRect,
        image: image!,
        fit: BoxFit.fill,
      );
    } else {
      canvas.drawRect(displayRect, Paint()..color = placeholderColor);
    }
    for (final stroke in strokes) {
      final paint = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          displayRect.topLeft + stroke.points.first,
          stroke.width / 2,
          Paint()..color = stroke.color,
        );
        continue;
      }
      path.moveTo(
        displayRect.topLeft.dx + stroke.points.first.dx,
        displayRect.topLeft.dy + stroke.points.first.dy,
      );
      for (final p in stroke.points.skip(1)) {
        path.lineTo(
          displayRect.topLeft.dx + p.dx,
          displayRect.topLeft.dy + p.dy,
        );
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AnnotatePainter old) =>
      old.image != image ||
      old.displayRect != displayRect ||
      old.strokes.length != strokes.length ||
      (strokes.isNotEmpty && !identical(old.strokes.last, strokes.last));
}
