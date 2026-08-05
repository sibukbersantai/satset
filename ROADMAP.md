# Satset roadmap — large, parallel, resumable transfers with an AirDrop-like UI

Technical plan for v1.1 → v2.0. Written against the code as it stands in v1.0.0.

## What the protocol already gives us

Read from the generated protobuf in `NearbyShare/Protobuf/offline_wire_formats.pb.swift`. **Satset currently handles none of these — every one of these frames is silently ignored today.**

| Wire feature | Fields | Status in Satset |
|---|---|---|
| `V1Frame.FrameType.AUTO_RESUME` (10) | `AutoResumeFrame { eventType, pendingPayloadID, nextPayloadChunkIndex, version }` with `PAYLOAD_RESUME_TRANSFER_START` / `_ACK` | ignored |
| `V1Frame.FrameType.AUTO_RECONNECT` (11) | reconnect negotiation | ignored |
| `PayloadTransferFrame.PacketType.PAYLOAD_ACK` (3) | per-payload acknowledgement | ignored |
| `PayloadTransferFrame.ControlMessage` | `{ event: PAYLOAD_ERROR / PAYLOAD_CANCELED / PAYLOAD_RECEIVED_ACK, offset }` | ignored |
| `PayloadChunk.offset` | `Int64` byte offset, already validated on receive | enforced, not used for recovery |
| `PayloadHeader.totalSize` | `Int64` | used for progress only |

So resume is **designed into the wire format at chunk granularity**, keyed by `pendingPayloadID` + `nextPayloadChunkIndex`.

### The open question, stated honestly

The frames exist in Nearby Connections' wire format. **It is not yet verified that Android's Quick Share actually negotiates `AUTO_RESUME` for this transfer type.** It may only be used for medium switches (Bluetooth → Wi-Fi Direct), not for connection loss. [PROTOCOL.md](/PROTOCOL.md) does not cover it.

This must be settled by experiment before any resume work is committed to — see M2.1. If Android turns out not to honour it, resume degrades to a Satset-side capability only: we can still avoid re-downloading bytes already on disk **when the sender re-offers the same payload**, but we cannot force a mid-stream resume.

## Current blockers in our own code

- **One serial queue for every connection.** `NearbyConnection.dispatchQueue` is a single FIFO queue shared by all connections ([NearbyConnection.swift:19](/NearbyShare/NearbyConnection.swift#L19)), with the comment "to avoid those exciting concurrency bugs". Nothing can run in parallel, and one large transfer starves every other.
- **Progress is a bare fraction.** The delegate carries `transferProgress(progress: Double)` and nothing else — no byte counts, no rate, no ETA.
- **No transfer state survives the process.** `transferredFiles` is in-memory only, so a crash or quit loses all partial-transfer knowledge even though the bytes are on disk.
- **UI lives in the share sheet.** Sending requires picking files first, and there is no persistent window, no drag-and-drop target, and no visual device picker.

## Milestones

### M1 — Realtime progress and ETA (v1.1)

Self-contained, no protocol changes, no dependency on unverified Android behaviour. Do this first.

1. Replace `transferProgress(progress: Double)` with a `TransferProgress` struct: `bytesTransferred`, `totalBytes`, `bytesPerSecond`, `eta`, `fileIndex`, `fileCount`.
2. Compute rate with an exponentially weighted moving average over a ~2 s window, so the ETA does not swing wildly on chunk boundaries.
3. Surface per-file *and* per-transfer aggregate progress; today only the aggregate exists.
4. Show it in the notification and in the new UI (M3).

### M2 — Resume without restarting (v1.2)

**M2.1 — Settle the question first.** Instrument a build to log every inbound frame type, then force a disconnect mid-transfer from Android and observe whether an `AUTO_RESUME` frame arrives. Nothing else in M2 starts until this is answered, and the answer gets written back into this file and PROTOCOL.md either way.

**M2.2 — Durable partial-transfer state.** Persist `{payloadID, destinationURL, bytesTransferred, totalSize, senderEndpointID, sha}` to a small store in Application Support, updated as chunks land. Write to a `.satset-part` file and only move into place on completion, so a partial file is never mistaken for a finished one.

**M2.3 — Implement the frames.** Handle `ControlMessage.PAYLOAD_RECEIVED_ACK` and emit `AutoResumeFrame(PAYLOAD_RESUME_TRANSFER_START, pendingPayloadID, nextPayloadChunkIndex)` on reconnect. Honour `PAYLOAD_ERROR` and `PAYLOAD_CANCELED` instead of treating every interruption as fatal.

**M2.4 — Reconnect loop.** On connection loss, retry with backoff while the transfer is still resumable, rather than surfacing an immediate failure.

### M3 — AirDrop-like interface (v1.2)

The point is familiarity: users already know AirDrop, so the closer this reads to it, the less there is to explain.

1. **A real window,** opened from the menu bar — not only the share sheet. The share extension stays for Finder → Share.
2. **Device grid** with large circular device tiles, name underneath, laid out like AirDrop's recipient list.
3. **Drag-and-drop onto a device tile** to send. This is the single biggest step toward AirDrop parity and removes the "pick files first" ordering.
4. **Circular progress ring around each tile** during transfer, with percentage in the middle, and the rate/ETA from M1 underneath.
5. **AirDrop's state vocabulary** on the tile: Waiting → Sending → Sent, Declined, Failed — with the same at-a-glance reading.
6. **Incoming transfers appear in the same window,** with Accept/Decline on the tile, so notifications become a convenience rather than the only path.

### M4 — Parallel and fast (v2.0)

1. **A queue per connection** instead of one global serial queue. The manager's shared collections were already moved onto the main queue in v1.0.0, which is the precondition that makes this safe.
2. **Concurrent transfers** to and from several devices, each with independent progress.
3. **Throughput work,** measured before and after on the same file: chunk size tuning, avoiding a full re-read per chunk on send, and checking whether `NWConnection` send batching helps.
4. **Large-file correctness.** `PayloadHeader.totalSize` is `Int64`, so the wire format is not the limit. Verify against multi-GB files that nothing buffers a whole payload in memory — `payloadBuffers` accumulates in RAM for `bytes` payloads and must never be used for file payloads.

## Sequencing

M1 is independent and lands first. M3 depends on M1 for the numbers it displays. M2 is gated on the M2.1 experiment. M4 is last because it is the most invasive and benefits from the tests written for M1–M3.

## Explicitly out of scope

Making Satset work without a shared Wi-Fi network. That is blocked at the OS level, not by this codebase — see [Limitations](/README.md#limitations) and [APPLE_ENHANCEMENT_REQUEST.md](/APPLE_ENHANCEMENT_REQUEST.md).
