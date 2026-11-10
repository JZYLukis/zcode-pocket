// 语音入口可用性回归（2026-10-28 开源准备批）：无 AGC 配置构建
//（开源自建包默认形态，测试环境天然如此——不传 dart-define）语音
// 入口整体隐藏而非点击报错：加号面板无 add-voice、其余入口不受牵连、
// 发送键空闲态不摆麦克风；覆写可用（=正式包）后入口恢复。
// 识别本体在无 HMS 设备上的失败路径由 voice_input_sheet 的 ABI 护栏
// 与 onError 分支承担，不属本测。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_composer.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/voice_input_sheet.dart'
    show debugVoiceRecognitionAvailable;

Future<void> _openAddSheet(WidgetTester tester) async {
  final app = AppState()..loaded = true;
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: const MaterialApp(
        home: Scaffold(body: ConversationPage(sessionId: null, title: '草稿')),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('add-trigger')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('无配置：面板无语音入口，其余入口不受牵连', (tester) async {
    // 不设覆写——测试环境 AGC_API_KEY 为空，即开源自建包形态。
    await _openAddSheet(tester);

    expect(find.byKey(const ValueKey('add-voice')), findsNothing);
    // 同面板其余入口照常（语音缺席不破面板）。
    expect(find.byKey(const ValueKey('add-attachment')), findsOneWidget);
    // entry-polish-1：add-usage 已移出加号面板（状态环为主入口）。
    expect(find.text('添加上下文'), findsOneWidget);
  });

  testWidgets('无配置：发送键空闲态不摆麦克风（退回箭头禁用态）', (tester) async {
    await _openAddSheet(tester);
    // 面板开着但 add-voice 已隐藏 → 全树无麦克风图标；发送键退箭头。
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('send-button')),
        matching: find.byIcon(Icons.arrow_upward),
      ),
      findsOneWidget,
    );
  });

  testWidgets('有配置（测试缝覆写=正式包）：语音入口恢复在场', (tester) async {
    debugVoiceRecognitionAvailable = true;
    addTearDown(() => debugVoiceRecognitionAvailable = null);
    await _openAddSheet(tester);

    expect(find.byKey(const ValueKey('add-voice')), findsOneWidget);
    // 面板入口与发送键（空闲=麦克风惯例）至少其一在场。
    expect(find.byIcon(Icons.mic_rounded), findsAtLeastNWidgets(1));
  });

  // D1-P1/D2-P2-02/D3-P1-1（三路，语音直发静默丢弃）：发送
  // 在途（_sending=RPC/附件上传等待/held 弹窗，可达分钟级）时长按发送
  // 键曾不受门控——听写后 onSend 撞 _sendText 的 _sending 早退=口述
  // 文本无痕丢失（不入草稿/队列/暂存，面板照常关闭）。长按与点按同闸。
  testWidgets('sending 态长按发送键不拉起语音；空闲态长按照常（与点按同闸）', (tester) async {
    debugVoiceRecognitionAvailable = true;
    addTearDown(() => debugVoiceRecognitionAvailable = null);
    var voiceOpened = 0;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    Widget host(bool sending) => AppStateScope(
      app: AppState()..loaded = true,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: InputBar(
            controller: controller,
            focusNode: focusNode,
            running: false,
            sending: sending,
            onSend: () {},
            onStop: () {},
            onVoice: () => voiceOpened++,
          ),
        ),
      ),
    );

    // 发送在途：长按不得拉起（修复前 onLongPress 不看 sending）。
    await tester.pumpWidget(host(true));
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(voiceOpened, 0,
        reason: 'sending 态长按拉起语音=听写后撞 _sending 早退静默丢弃');

    // 空闲态：长按照常拉起（门控不误伤正常路径）。
    await tester.pumpWidget(host(false));
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(voiceOpened, 1, reason: '空闲态长按语音入口照常');
  });
}
