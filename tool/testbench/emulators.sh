#!/usr/bin/env bash
# Starts the Firebase Auth and Firestore emulators for the testbench and
# forwards their ports to every connected phone over USB (no Wi-Fi needed,
# nothing written to the real project). Runs in the foreground; Ctrl-C stops.
#
# The app only uses them when built with:
#   flutter build apk --profile --dart-define=USE_FIREBASE_EMULATOR=true
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OT="$ROOT/tool/testbench/ot.sh"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
for serial in $("$OT" devices | awk '$2 == "device" {print $1}'); do
  "$OT" reverse "$serial" && echo "ports forwarded to $serial"
done
cd "$ROOT"
exec firebase emulators:start --only auth,firestore --project onetime-bf68b
