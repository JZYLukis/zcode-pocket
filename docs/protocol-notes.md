# ZCode remote-control protocol overview (V4)

This document is a **map, not a specification**. ZCode Pocket is an unofficial
client; protocol behavior is implemented against the official open-source
implementation and verified by observing real traffic. When this page and the
official code disagree, the official code wins.

It is written for contributors who need to understand where a bug probably
lives, not as a wire-level contract. Field names below are indicative; the
authoritative definitions live in the official implementation.

## 1. Layers

```
phone app ──WebSocket(JSON)──► relay (wss://zcode.z.ai) ◄──WebSocket── desktop
   │            envelope {type:"data", payload:{zcode_type:...}}
   └── rpc-frame (base64 + CRC32 + messageSeq fragments) ──► workspace bridge
                                                              │ Channel RPC
                                                              ▼
                                                          agent / CLI
```

Four layers must be kept separate when implementing or debugging:

| Layer | Responsibility |
|---|---|
| Relay | pairing, authentication, heartbeat, reconnect, JSON envelope |
| rpc-frame | fragmentation of byte-oriented RPC messages over JSON |
| Channel | VSCode-style binary RPC (channel + method + arguments, events) |
| V4 protocol | conversation snapshots/deltas/commands (`zcode-protocol-v4`) |

A phone client that establishes the bridge is a full V4 client, using the same
subscribe/frame schema as the desktop.

## 2. Connection lifecycle

- **Relay endpoint**: `wss://zcode.z.ai/ws`, WebSocket text frames carrying
  JSON. A single physical frame is capped at 1 MiB.
- **Pairing (current)**: the desktop authorizes a phone through the account
  session: a short-lived one-time token is exchanged for a relay connection
  bound to a device session. The QR/pairing payload is a URL whose query
  carries the device session identifier, device id, display name and desktop
  app version. Treat the whole URL as a credential while it is valid.
- **Heartbeat**: both sides exchange periodic heartbeat frames; the desktop
  and relay treat a silent connection as unhealthy after a timeout. ZCode
  Pocket raises the interval while backgrounded to reduce radio wakeups, and
  shortens it again in the foreground.
- **Reconnect**: exponential backoff with a cap, reset after a successful
  pairing. There is no WebSocket-level resume token — recovery is
  application-level: re-bootstrap, then reopen the workspace bridge with a new
  bridge session id and generation.
- **Bridge**: `workspace-bridge-open` (session id, generation, workspace key,
  optional task) → `workspace-bridge-ready` with a recovery id. Every
  subsequent rpc-frame carries the bridge identity; identity mismatches are
  dropped.
- **Degradation**: frame gaps, CRC failures, buffer overflows or timeouts
  produce `bridge-degraded`. Recovery is a hard bridge rebuild, not local
  patching of the stream.
- **Single terminal**: for one device session, a second authenticated phone
  causes the relay to send `KICKED` to the previous one. Different desktops
  are different sessions; the protocol itself allows a phone to hold several
  relay connections, one per desktop.

## 3. RPC transport (rpc-frame)

- A logical message is split into slices (512 KiB), base64-encoded, and placed
  in JSON envelopes carrying a physical sequence number, a logical message
  sequence number, fragment index/count, total byte length and a CRC32
  checksum. The receiver reassembles and acknowledges the logical sequence.
- Official limits: physical frame ≤ 1 MiB, logical message ≤ 16 MiB, ≤ 64
  fragments, 30 s assembly timeout. This client **sends** within the official
  limits (the official receiver silently drops anything larger) but is
  **tolerant on receive** up to 64 MiB / 256 fragments — long-context
  snapshots can legitimately exceed 16 MiB, and dropping them used to leave
  the UI spinning forever. Inbound assembly is resource-capped (concurrent
  assemblies and staged bytes, evicting the oldest when full) and a decoded
  fragment larger than the 1 MiB physical-frame budget is discarded.
- Physical or logical sequence gaps are terminal faults, not something the
  application layer may silently skip.
- CRC32 uses the standard reflected polynomial (`0xedb88320`), rendered as
  eight lowercase hex characters.

## 4. Channel layer

- Each rpc-frame logical message is one Channel body. There is **no** 13-byte
  IPC header on this path; that header belongs to the LAN transport only.
- Values are tagged (undefined, string, buffer, VSBuffer, array, object,
  integer) with 7-bit little-endian varints for lengths/counts.
- Requests are `[reqType, reqId, channel, methodName]` plus arguments;
  responses are `[respType, reqId]` plus a return value. Request types cover
  promise/cancel/event-listen/event-dispose; response types cover
  initialize/success/error/error-object/event-fire.
- Events: `addEventListener(channel, eventName, arg)` returns a disposer.

## 5. V4 conversation protocol

### Handshake

After the bridge is ready, the client performs `helloConversationV4` (which
returns a connection id required for attachments) and
`initializeConversationV4` with a client hello declaring `protocolVersion: 3`,
a client id, `clientKind: "mobileApp"` and an app/protocol capability version.
Declaring an old capability version disables newer capabilities; the app uses
a recent desktop capability version and recalibrates it when the desktop
upgrades.

### Topics and frames

Three topic families are used: `conversation/<sessionId>`,
`sessions-index/<workspaceId>`, `workspace-config/<workspaceId>`; the desktop
additionally exposes aggregate `controller/workspaces` and
`controller/tasks-index`.

Every frame has the shape:

```
{topic, subscriptionId, fromSeq, toSeq, sentAt,
 payload: {kind: "snapshot", snapshot} | {kind: "deltas", deltas: [...]}}
```

Apply rules (no out-of-order reordering):

1. `snapshot` replaces the whole local state and sets `seq = toSeq`;
2. `toSeq <= local seq` is late/duplicate and is dropped;
3. `fromSeq != local seq` is a gap → single-flight resync (force a snapshot if
   resume fails).

Each topic has its own `logEpoch` (publisher generation). An epoch change
means the old sequence cannot be resumed; a snapshot is required.
`subscriptionId` is a subscription generation — frames from an older one are
discarded.

### Rows and deltas

A conversation snapshot contains a window of rows, control/phase, model
config, queue, usage/context, goal, plan, background work, input routing,
pending interactions and a revision. Rows are self-contained and come in nine
kinds: turn header, user input, assistant text, reasoning, tool call,
artifact, subagent, hook invocation, timeline marker.

Delta operations are: append a row, upsert a row (row content changes are
whole-row replacements), remove rows before an id, append to a text path
(`text`, `inputText`, `output.text`, `summaryText`), and patch state by
replacing keys.

Snapshots carry only a tail window of rows (60 in current builds). Older
history is fetched with `conversationRowsRangeV4` using the oldest held row id
as a cursor; the page limit is 200 rows.

### Streaming profile

Mobile clients use the replayable delivery profile: a 150 ms flush window
(desktop uses 30 ms), and only assistant text/reasoning body text is streamed.
Tool input, tool output text and summaries are delivered once in their final
form. Terminal tool output is head+tail truncated (32 KiB each) and can be
fetched by reference. The typewriter effect is therefore batched at 150 ms,
not per token.

### Commands

Commands are sent through `v4/command` with an envelope containing a client
command id, client id, session id, optional base revision/epoch, type, payload
and issue time. Acknowledgements report accepted/rejected/stale/duplicate/
noop/failed. Commands that mutate state are compare-and-swap: they carry a
base revision, and a `stale` response must be retried once with the returned
revision. Reusing the same command id on retry is how the server deduplicates.

Command types include creating a session, sending text, goals, stop, compact,
resolving an interaction (approval), model/mode/thought switching, file
rewind, editing a user query, retrying a turn, queue operations, forking,
renaming and deleting.

### Attachments

Messages carry only references. Bytes move in a chunked transaction:
`attachmentBeginV4` (file name, mime, total bytes, chunk count, SHA-256) →
`attachmentChunkV4` (base64, ≤ 512 KiB decoded per chunk) →
`attachmentCommitV4` returning the reference. The total is capped at 20 MiB.
Downloads use `attachmentReadV4` with offset/limit until exhausted.

## 6. Interactions and notifications

There is **no separate mobile push channel**. Every notification is derived
from subscription state:

- task-level: diffs of the sessions index (phase transitions, background work,
  pending-interaction summary);
- conversation-level: `control.phase`, `pendingInteractions`, `goal`
  milestones in state patches;
- list-level: relay workspace-list updates.

This is why an accurate phone notification implementation is a state-diff
problem, and why the app can notify without any server-side push service.

## 7. LAN fallback

The desktop can expose a local channel via `zcode --web` (default
`127.0.0.1:3030`, `--host 0.0.0.0` to listen on the LAN). It is a different
transport from the relay:

- `GET /ws` is a bare binary RPC channel; `?token=` may be exchanged for an
  HttpOnly cookie; non-local listeners generate an access token.
- Frames carry a 13-byte header `[type:u8][id:u32be][ack:u32be][bodyLen:u32be]`
  around the same Channel payloads. There are no device/terminal roles and no
  JSON envelope on this path.

The app models this behind a transport interface so the Channel/V4 layers are
shared between relay and LAN.

## 8. How to verify a protocol claim

1. Read the official open-source implementation for the desktop version you
   are targeting; note the version you read.
2. Run a desktop with a workspace and connect a test client. Capture WebSocket
   frames at the relay or use the LAN channel to avoid the relay entirely.
3. Compare: envelope types, bridge identity, topic/epoch/seq behavior, row and
   delta shapes, command acknowledgements.
4. Do not paste tokens, pairing URLs, device ids or workspace paths into
   issues. Redact query strings before sharing logs.

Compatibility expectations: the protocol is additive. Unknown `zcode_type`
values and unknown fields must be ignored rather than treated as errors; new
optional fields appear without a protocol-version bump. A desktop upgrade can
therefore break assumptions without breaking the version number — verify
against the new implementation before filing a protocol bug.
