# Testbench

Drives two physical Android phones over `adb` for end-to-end tests. The reader's camera must point at the source's screen (about 15–25 cm away).

## Setup

- USB debugging enabled on both phones, "Stay awake" on, plugged into the Mac.
- Debug APK built: `flutter build apk --debug`.
- Firebase config present (`lib/firebase_options.dart`, `android/app/google-services.json`).

## Run

```bash
tool/testbench/ot.sh install
tool/testbench/scenario_exchange.sh <source-serial> <reader-serial> "8 KB"
```

The scenario wipes app data on both phones, then checks: onboarding, joining by scanning the conversation QR, key exchange (same key fingerprint and full requested size on both phones), pseudo exchange, and one message in each direction. Screenshots of both phones are saved to `build/testbench/` on failure.

`ot.sh` also works on its own: `ot.sh ui <serial>` lists what is on screen, `ot.sh tap <serial> <label>` taps by label, `ot.sh events <serial>` prints milestone events.

## Milestone events

Debug builds log one line per milestone (`lib/services/test_events.dart`):

```
OT_TEST {"event": "key_saved", "role": "reader", "bytes": 8192, "fingerprint": "…"}
```

Events: `conversation_created`, `conversation_joined`, `key_saved`, `message_sent`, `message_decrypted`. Release builds emit nothing.

## Baseline (Nov 2026, REVVL 2 source → Pixel 3 reader, QR torrent mode)

Time from the size button to the key saved on both phones.

| Key | Before Phase 1 | Phase 1 (rotation fix) | Phase 2a |
|---|---|---|---|
| 8 KB | 15–16 s | 13 s | 10 s |
| 32 KB | 34 s | 27 s | 18 s (~1.8 KB/s) |

Phase 2a steps, measured at 32 KB:

| Change | 32 KB |
|---|---|
| Base45 payload in alphanumeric mode (QR 141 → 125 modules), 600 ms rotation | 26 s |
| Reader acknowledges in the background, in batches; 300 ms rotation | 21 s |
| Error correction L instead of M (QR 125 → 109 modules) | 18 s |

The Pixel reads every code it is shown: scanning is bound by the rotation
interval. About 8 s of each exchange is fixed overhead (session setup,
finalization). The REVVL sees the reader's acknowledgements several seconds
late, so ack-driven rotation shows segments again that were already read.
