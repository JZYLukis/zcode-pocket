# Contributing

Thanks for your interest! （欢迎参与）

- Open an issue first to discuss significant changes. Chinese or English
  are both fine. （较大改动请先开 issue 讨论，中英文均可）
- Before reporting behavior you suspect is a bug, check
  [docs/decisions.md](docs/decisions.md) and the `known-limitation` issues —
  it may be an intended trade-off, and each entry says what it costs.
  （报告疑似 bug 前先查 docs/decisions.md 与 known-limitation issue——可能
  是有意取舍，每条都写了代价）
- Setup: see the **Build** section in the README (Flutter 3.47.x
  recommended; `flutter pub get && flutter build apk --split-per-abi`).
- Before sending a PR, make sure `flutter analyze` and `flutter test`
  pass inside `app/` — CI runs both on every PR, plus a debug build to
  confirm the tree still compiles.
- Keep PRs focused: one topic per PR.
- Note: this is an unofficial third-party client. Anything that depends
  on the official Web Remote Control protocol may need verification
  against the official open-source implementation before it can be
  implemented here.
