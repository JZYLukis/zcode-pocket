> Note: the paths below are relative to the `app/` directory.
# 第三方来源声明

> English summary: ZCode Pocket derives part of its transport layer
> from zemote (MIT; full text below), follows the official ZCode
> open-source repository (Apache 2.0) for protocol behavior and UI
> strings, uses brand icons from Simple Icons (CC0), and bases its
> launcher mark on ZCode public assets with original additions.
> Trademarks belong to their respective owners; see each section
> below for details.

## zemote (MIT)

`lib/transport/` 下的协议层部分模块（connection_params / crc32 / id /
ipc_codec / proof / channel_client / relay_client / rpc_frame_transport
（原 rpc_transport）/ companion_client（原 zemote_client）/ conversation /
automation_client / device_info）最初移植自
[HumanAILoop/zemote](https://github.com/HumanAILoop/zemote)
（MIT License，已停更仓库），类名已从 Zemote* 重命名为 Companion*；
其后各模块持续对照官方开源实现进行了重写与加固（详见各文件内溯源
注释）。上述文件头部均带 `SPDX-License-Identifier: MIT` 标记单文件
来源；`lib/transport/` 其余模块（project_tree / protocol_drift /
relay_v2 / z_transport）为本项目原创，不属移植范围。

MIT License 全文（内嵌于本文件，满足 MIT 保留许可声明的要求）：

> MIT License
>
> Copyright (c) 2026 Zemote contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## ZCode 官方仓库（Apache 2.0）

官方开源仓库（zai-org/ZCode）的源码快照用于协议与设计参考；界面
文案（`lib/core/official_l10n.g.dart`）由官方开源本地化资源生成。
官方声明文件一并保留于 `NOTICE-ZCode.md`。应用启动图标的 Z 图形
来源见下文专节。

## 品牌图标（Simple Icons，CC0）

`assets/brand_logos/` 下的第三方品牌图标（Anthropic/Claude/DeepSeek/
Gemini/Kimi/Meta/Mistral/Moonshot/OpenAI/Qwen 等）取自
[Simple Icons](https://simpleicons.org/)（CC0 1.0 通用公共领域贡献）。
品牌商标归各自所有者，本应用仅在模型选择等界面作识别性展示。
其中 `zhipu.svg` 来自智谱官方 CDN（z-cdn.chatglm.cn）。

## 设计参考（paseo）

部分交互与视觉细节（差异预览、输入区圆角与密度等）参考了开源项目
paseo 的设计；仅参考设计，未复制其代码。

## 应用启动图标

`android/app/src/main/res/mipmap-*/ic_launcher.png` 的 Z 图形取自
ZCode 官方公开仓库的标识素材，并叠加了自有的渐变色带与 POCKET
字样以示区分。ZCode 名称与标识的权利归其所有者；本项目为非官方
第三方客户端，使用该元素仅为表明与 ZCode 的兼容关系，不代表官方
出品或背书。如权利方要求，将更换为独立设计的标识。
