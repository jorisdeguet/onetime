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

| Key | Exchange time |
|---|---|
| 8 KB | 15–16 s |
| 32 KB | 34 s (~1 KB/s) |
