# ZCode Pocket

**English** | [简体中文](README.zh-CN.md)

A native Android client (Flutter) for the ZCode desktop app. It brings
multi-computer management, the task home, streaming conversations, approval
interactions, branch selection, usage stats and more to your phone, keeping
interaction habits consistent with the desktop. It connects to ZCode's
official Web Remote Control channel (relay + V4 protocol); you need your own
ZCode account and a running desktop.

> **Unofficial project disclaimer**: This is a community-driven third-party
> client. It is not affiliated with, authorized by, or endorsed by
> ZCode / Zhipu. The ZCode name belongs to its owner. Protocol behavior is
> implemented against the official open-source implementation; no official
> runtime code is included. UI strings are generated from the official
> open-source localization resources (Apache 2.0; see third-party notices).
>
> **Service usage notice**: This repository contains client code only. When
> using it with the official ZCode service you must comply with the official
> terms of service (zcode.z.ai/cn/terms) — the current terms default to
> non-commercial personal research and study; commercial use requires a
> separate agreement with the provider.

## Features

- Multi-computer / multi-account management (parallel online, isolated
  profiles, computer nicknames, read-only task snapshots of other computers)
- Task home: all tasks grouped by time/project, project ordering, pin,
  archive, batch actions
- Conversations: streaming output, tool-call display, approvals, subagent
  list & drill-down, context compaction, in-conversation full-text search,
  notification deep links
- Projects / branches: workspace project tree, branch picker for new chats
- Input: persistent drafts (isolated per computer/account/workspace/
  conversation), offline send queue, attachments, screenshot annotation,
  voice input (system recognizer)
- Workflows: run catalog and artifact viewing (text/HTML preview)
- Usage: subscription usage, heatmap (total / per-model), daily and
  per-model breakdowns and trends
- Appearance: light/dark themes, Chinese/English UI, foldable-unfolded and
  wide-screen dual pane, font scaling
- About page: unofficial disclaimer, service-terms notice, privacy notes,
  project license and third-party notices (bundled offline)

## Requirements

- Android 7.0+ (minSdk 24; arm64 / armv7 / x86_64, arm64 recommended)
- A ZCode account you can sign in with, and a running desktop (or cloud
  session)
- Logical screen width 320dp–840dp (portrait is the only main orientation)

## Installation

Grab a prebuilt APK from [Releases](https://github.com/JZYLukis/zcode-pocket/releases)
(most phones: `arm64-v8a`) — or build from source below. Before mixing the two,
read [Signing and switching builds](#signing-and-switching-builds): the
signatures differ and switching requires uninstalling, which erases local data.

## Build

```bash
flutter pub get
flutter build apk --split-per-abi
```

Without `app/android/key.properties`, release builds fall back to debug
signing (fine for personal use); configure your own signing for wider
distribution.

### Signing and switching builds

The prebuilt APKs are signed with the maintainer's release keystore. A build
made from this repository without `app/android/key.properties` uses the
Android debug keystore instead, so the two have **different signatures**.

Android refuses to update an installed app with an APK signed by a different
key (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). To switch between the prebuilt APK
and your own build you must uninstall the old app first. **Uninstalling erases
local data** — signed-in accounts, paired computers, drafts, the offline send
queue — and there is no cloud backup (`allowBackup=false`).

To keep receiving updates without uninstalling, always build with the same
keystore and keep using that build. Fill four keys in
`app/android/key.properties` (values from your own keystore):

| Key | Meaning |
|---|---|
| `storeFile` | keystore path (relative paths resolve inside `app/android/app/`) |
| `storePassword` | keystore password |
| `keyAlias` | key alias |
| `keyPassword` | key password |

Do not commit the keystore or this file; the repository `.gitignore` already
excludes them.

### Voice input

Speech recognition uses the standard system service (Android
SpeechRecognizer) — no keys or extra setup required. Devices with a
recognition service work out of the box; the entry hides itself when none is
available. Optional transcript polishing supports Zhipu / DeepSeek / Kimi
with your own API keys in settings.

## Background & battery

- The app disconnects about 90 seconds after backgrounding (by design) and
  reconnects automatically on return.
- With the "approval alerts" switch enabled it stays connected in the
  background for real-time alerts, with correspondingly higher battery use.
  For stable background behavior on vendor ROMs, allow
  **auto-launch / associated launch / background activity** for this app in
  system settings (location varies by vendor, usually under battery or
  startup management).

## Privacy

- No telemetry, no third-party analytics, no ads. Conversation and task data
  go only to the ZCode desktop / official service you configure.
- Account credentials are stored in the Android keystore; Android backup is
  disabled (`allowBackup=false`), so app data is not copied into cloud
  backups.
- **Lock screen**: by default Android may show notification content on the
  lock screen. ZCode Pocket notifications contain the task title and up to
  60 characters of the latest assistant reply; the optional foreground
  connection notification also shows the name of the running task. To hide
  this, enable "hide sensitive notification content" (or disable lock-screen
  notifications) for ZCode Pocket in system settings.

## Known limitations

- Portrait-first; wide screens and foldables unfolded (≥600dp) use a
  dual-pane layout (task list + conversation); the large-tablet layout is
  still being polished.
- No built-in image/PDF preview (the protocol has no file-byte channel);
  only newly created HTML files can be previewed.
- Not applicable to HarmonyOS NEXT (Android APK).
- Verified mainly on mainstream Android and foldable devices; other devices
  are welcome to open issues.

## Maintenance

Maintained by [@JZYLukis](https://github.com/JZYLukis). Please open an issue
for problems and feedback.

## License

Apache License 2.0 (see LICENSE).
