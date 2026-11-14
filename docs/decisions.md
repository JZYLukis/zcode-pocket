# Design decisions

A short, public-facing summary of the choices that shape ZCode Pocket. It is
not a full decision log: it records the constraints that keep coming back in
bug reports and pull requests, so contributors can tell a bug from an intended
trade-off.

How this list is maintained: the project keeps a full internal decision log
(with incident narrative, review rounds and maintainer deliberations that are
not written for publication); this page is the public digest of the decisions
that affect users and contributors. If a behavior looks wrong, check this
page and the `known-limitation` issues first — if it is not covered, please
open an issue. Decisions here can be challenged and changed; when one changes,
this page changes with it.

## 1. Unofficial client, protocol learned from the official implementation

**Problem**: there is no public SDK for the Web Remote Control channel.
**Decision**: implement against the official open-source desktop code and
observed traffic; do not copy official runtime code; keep the unofficial
disclaimer visible in the app and README.
**Cost**: every desktop upgrade can invalidate an assumption; protocol work is
continuous, and some features cannot be offered at all (see #12).

## 2. Relay first, LAN as a fallback

**Problem**: the phone is often not on the same network as the desktop.
**Decision**: the primary transport is the official relay
(`wss://zcode.z.ai`); the desktop's `zcode --web` channel is a secondary
transport behind the same abstraction.
**Cost**: two transports to maintain; the relay path depends on the official
service being reachable and on its terms.

## 3. One phone session per desktop, several desktops in parallel

**Problem**: the relay allows one terminal per device session; a second one
kicks the first.
**Decision**: isolate each desktop in its own profile/connection instead of
pretending a single connection can serve several desktops; switching desktops
is an explicit action.
**Cost**: N desktops means N connections and N credential sets; the UI must
make "which computer am I looking at" unambiguous.

Note (desktop-side): the one-terminal rule is per running desktop instance.
Running two desktop instances on one machine with isolated data roots
(`ZCODE_DATA_BASE_DIR`) gives each account its own instance — a workaround
outside this app's scope, but useful to know.

## 4. Disconnect about 90 seconds after backgrounding

**Problem**: a permanently open WebSocket keeps waking the radio.
**Decision**: by default, drop the connection ~90 s after the app goes to the
background and reconnect on return. Only the optional approval-alert mode
keeps a background connection.
**Cost**: no real-time task-completion notification unless approval alerts are
enabled; returning to the app costs a reconnect and a cache refresh.

## 5. Background heartbeat is widened, not removed

**Problem**: a 5 s heartbeat in the background dominated battery use while the
relay tolerated much quieter clients.
**Decision**: widen the heartbeat interval while backgrounded (with a matching
watchdog widening), restore it in the foreground. Any in-flight watchdog must
be rescheduled when the interval changes.
**Cost**: background commands can take longer to notice a dead link; the
timing rules are subtle and are covered by dedicated tests.

## 6. Cache snapshots, but never rewrite identical bytes

**Problem**: frequent full rewrites of device/task snapshots cost I/O and
wakeups without changing content.
**Decision**: keep read-only snapshots for fast cold starts, and skip writes
when a content fingerprint is unchanged.
**Cost**: a stale snapshot is possible until the first live frame; staleness is
shown in the UI rather than hidden.

## 7. Task-centric home, projects as grouping

**Problem**: a top row of project chips made switching and sorting awkward on
a phone, and duplicated the task list.
**Decision**: one task home grouped by time and project, with project ordering
and pinning; project selection lives in the new-task flow and in the project
groups.
**Cost**: one extra tap to "browse a project"; wide-screen layouts need a
separate compact treatment.

## 8. Dual pane on wide screens, single column on phones

**Problem**: foldables and tablets have room for a list and a conversation.
**Decision**: at ≥600 dp logical width, show a task list on the left and the
selected conversation on the right; below that, keep the single-column flow.
**Cost**: two navigation models to test; the secondary pages (settings, usage)
are still full-screen.

## 9. Drafts are persisted, and uncertain sends are never automatic

**Problem**: mobile apps are killed in the background; losing a long message
is unacceptable.
**Decision**: persist drafts per computer/account/workspace/conversation,
flush on background, and mark a send as "in flight" on disk. If the app dies
mid-send, show "result unknown, check before resending" instead of resending.
**Cost**: extra local state and edge cases (attachment expiry, deleted tasks,
account switches) that must be cleaned up explicitly.

## 10. Offline queue only holds messages that were never sent

**Problem**: users type while disconnected and expect the message to go out
after reconnecting.
**Decision**: queue only messages for which no send was ever attempted; once a
send has been attempted, the uncertain-send rules from #9 apply.
**Cost**: attachments cannot be queued (upload needs a connection); queued
messages are replayed in order and stop at the first failure.

## 11. Search is literal, local and occurrence-based

**Problem**: full-text search over a long conversation must work offline and
match what the user sees.
**Decision**: case-insensitive literal matching over loaded rows, occurrence
counts, previous/next navigation, and lazy loading of older history with an
explicit "loaded range only" note while running or offline.
**Cost**: very long histories need paging; search is not semantic and does not
index reasoning content.

## 12. File access rides the artifact channel; no general byte-read method

**Problem**: the protocol exposes conversation file changes and workflow
artifacts, but no general "read arbitrary file bytes" method — so
conversation-generated files (images, PDFs, spreadsheets) cannot be fetched
directly.
**Decision**: three layers. (1) Preview locally what already arrives: newly
created HTML and plain-text files (Markdown/CSV/JSON/code) come with their
full text in the change payload. (2) Workflow artifacts have a real byte
channel (chunked reads): image artifacts preview, and any artifact —
including binaries — can be downloaded and shared to the system share sheet.
(3) For conversation-generated files, a one-tap "Collect artifacts" command
asks the agent to publish that turn's files as workflow artifacts, making
them downloadable without paying tokens per byte. Binary artifacts that
cannot be previewed get a clean "preview not supported" page with a share
entry, never a wall of mojibake; file names missing an extension get one
from magic-byte sniffing.
**Cost**: downloading conversation files is a two-step, agent-mediated path
rather than a direct save; a huge conversation file still costs the agent a
read+write round-trip. It will be simplified if the official protocol adds a
general byte channel.

## 13. Light-first visual system, dark follows the system

**Problem**: the desktop has an established black/white skeleton with a single
accent color; a phone client that invents its own palette feels foreign.
**Decision**: light theme is the design baseline, dark theme follows the
system setting, and both use the same tokens. Status is conveyed by motion and
a small number of semantic colors, not by decoration.
**Cost**: every new surface must be checked in both themes; contrast and
baseline tests are part of CI.

## 14. No telemetry, and exports go through an allow-list

**Problem**: a client that holds account credentials must be auditable.
**Decision**: no analytics or crash reporting; credentials live in the system
keystore; Android backup is disabled; the public source tree is produced by an
allow-listed `git archive` export with a sensitive-string, credential and image
metadata check.
**Cost**: no field diagnostics from users; bugs are reproduced locally, and the
export step is deliberately strict.

## 15. Release identity is SemVer + a date build code

**Problem**: version numbers used to depend on whatever was installed on a
test device.
**Decision**: user-visible versions use SemVer; `versionCode` is
`YYYYMMDDNN`; release builds embed the commit SHA in `versionName`; a release
is an annotated tag that never moves.
**Cost**: version bookkeeping is manual at the release window; rebuilding the
same version is discouraged, and a bad release is superseded by the next
patch.

## 16. Voice input uses the system recognizer by default

**Problem**: vendor speech engines are not portable and add large native
dependencies.
**Decision**: use Android's standard `SpeechRecognizer` when available, hide
the entry when it is not, and keep optional transcript polishing behind
user-supplied API keys. Vendor-specific engines are not part of the public
build.
**Cost**: recognition quality and availability depend on the device; some
devices ship no recognition service.

## 17. Protocol compatibility is additive and tolerant

**Problem**: the desktop upgrades independently of the phone app.
**Decision**: ignore unknown envelope types and fields, treat new optional
fields as absent-safe, and verify protocol assumptions against each desktop
version before shipping a fix.
**Cost**: silent behavior changes are possible; the app needs explicit
compatibility checks and conservative fallbacks for write operations.

## 18. Release binaries are signed locally, never in CI

**Problem**: building release APKs in CI would require the release key to
live on the CI provider; secrets on hosted runners are a known exfiltration
surface and would move the single point of trust off the maintainer's machine.
**Decision**: releases are built and signed locally; CI never signs or
publishes — it runs analysis, tests, a debug build and a
release-configuration compile (no secrets, artifact discarded) to prove the
public tree builds. The signing certificate SHA-256 and per-APK checksums
are published (README "Verifying downloads"; CHANGELOG "Checksums" sections
from v1.0.2 onward), so anyone can verify a downloaded APK against the
published fingerprint.
**Cost**: builds are not provenance-attested by CI; trust rests on the
published fingerprint and checksums instead of on a CI trail.

## 19. The public source tree is a filtered export, not the dev repo

**Problem**: the development repository contains incident narrative, review
notes and tooling that are not written for publication.
**Decision**: the public tree is generated by a script that exports an
allow-listed subset of a specific commit, strips vendor-specific build
configuration and all signing material, and runs machine checks (sensitive
strings, credentials, signing material, image metadata) before anything is
pushed; a CI job additionally rejects machine-detectable internal ticket
codes in code files on every pull request. Some Chinese development notes
(batch markers, decision pointers) remain in comments by policy: they carry
reasoning, contain nothing sensitive, and mechanically rewriting comment
text has broken code before.
**Cost**: public-tree comments are a mix of English and Chinese notes; the
full reasoning behind a decision is summarized on this page instead of
sitting inline.

## 20. Incidents are disclosed, not quietly patched

**Problem**: trust in third-party binaries comes mainly from how bad news is
handled.
**Decision**: release-level incidents are recorded in the CHANGELOG with
their impact and remedy. For example, the first-hour v1.0.2 APKs were
mistakenly signed with the debug key; they were replaced the same day with
correctly signed builds (same version code), and affected users were told to
re-download.
**Cost**: admitting mistakes publicly, and keeping that discipline even when
it is inconvenient.

## 21. Notifications are derived from state, not pushed

**Problem**: the protocol has no independent push channel the client can
rely on today (the official service has a server-side mobile push
capability, but it is not enabled by default).
**Decision**: notifications are computed on-device from subscription state
diffs; anything real-time in the background requires a live connection,
which only the optional approval-alert mode keeps (#4).
**Cost**: no background task-completion pings while disconnected;
notification fidelity is bounded by what the subscribed state carries.

## 22. Every release candidate passes one quality gate

**Problem**: a solo-maintained client needs machine discipline more than a
team does.
**Decision**: a release window runs static analysis, the full test suite,
design-token guards, privacy guards and an emulator smoke test as a single
gate with one pass/fail result; new UI surfaces additionally get a rendered
walkthrough before a build is installed on a real device.
**Cost**: releases are slower; the gate itself needs upkeep as the project
grows.

## 23. Portrait is the only orientation

**Problem**: landscape support would double layout testing for little use in
this workflow (chat and approvals are used while holding the phone).
**Decision**: portrait is the design target in both folded and unfolded form
factors; a wide unfolded screen gets the dual-pane home (#8) rather than a
landscape mode.
**Cost**: landscape users are out of scope until there is real demand for it.

## 24. Errors are translated, not surfaced raw

**Problem**: protocol and platform failures arrive as codes or stack traces
that mean nothing on a phone screen.
**Decision**: known failure classes map to short human sentences, with a
retry action where one is meaningful; a raw code leaking into the UI is
treated as a bug, not as acceptable output.
**Cost**: the mapping needs maintenance as the protocol grows; rare unknown
failures fall back to a generic message plus local logs.

## 25. Support scope: current desktop version first, best effort elsewhere

**Problem**: one maintainer cannot regression-test the desktop × device
matrix.
**Decision**: the primary target is the desktop version the maintainer
actually runs; other versions get best-effort fixes; known limitations are
tracked as issues rather than promised away.
**Cost**: older desktop versions may stay broken longer; issue reports are
the main coverage for other environments — the bug report template asks for
the app version, the device, and the ZCode desktop version.
