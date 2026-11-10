#!/usr/bin/env bash
# OneTime testbench: drive Android phones over adb by UI label.
#
# Usage: tool/testbench/ot.sh <command> [args]
#   devices                      list connected devices
#   install [serial...]          install the debug APK (all devices if none given)
#   launch <serial>              (re)start the app
#   reset <serial>               clear app data (fresh install state)
#   ui <serial>                  print visible labels with tap coordinates
#   tap <serial> <label>         tap the first element whose label contains <label>
#   field <serial>               focus the first text field
#   type <serial> <text>         type text into the focused field
#   key <serial> <keycode>       send a key event (e.g. BACK, ENTER)
#   shot <serial> [file]         save a screenshot (default: <serial>.png in $OT_OUT)
#   wait <serial> <label> [sec]  wait until a label is visible (default 20 s)
#   events <serial>              print OT_TEST milestone events from logcat
#   clearlog <serial>            clear logcat
set -euo pipefail
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
PKG="org.deguet.jo.onetime"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APK="${OT_APK:-$ROOT/build/app/outputs/flutter-apk/app-debug.apk}"
OT_OUT="${OT_OUT:-$ROOT/build/testbench}"
mkdir -p "$OT_OUT"
dump_ui() {
  "$ADB" -s "$1" shell uiautomator dump /sdcard/ot_ui.xml >/dev/null 2>&1
  "$ADB" -s "$1" exec-out cat /sdcard/ot_ui.xml
}
# Prints "x y label" for every node that has a label (content-desc, text or hint)
list_ui() {
  dump_ui "$1" | python3 -c '
import re, sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
for n in root.iter("node"):
    label = n.get("content-desc") or n.get("text") or n.get("hint") or ""
    if not label.strip():
        continue
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", n.get("bounds")))
    print((x1 + x2) // 2, (y1 + y2) // 2, n.get("class").split(".")[-1], label.replace("\n", " | "))
'
}
find_label() {
  list_ui "$1" | awk -v l="$2" 'index(tolower($0), tolower(l)) { print $1, $2; exit }'
}
cmd="${1:-}"; shift || true
case "$cmd" in
  devices) "$ADB" devices -l ;;
  install)
    serials=("$@")
    [ ${#serials[@]} -eq 0 ] && serials=($("$ADB" devices | awk 'NR>1 && $2=="device" && $1 !~ /^emulator/ {print $1}'))
    for s in "${serials[@]}"; do echo "== $s"; "$ADB" -s "$s" install -r "$APK" | tail -1; done ;;
  launch)
    "$ADB" -s "$1" shell am force-stop "$PKG"
    "$ADB" -s "$1" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 ;;
  reset) "$ADB" -s "$1" shell pm clear "$PKG" ;;
  ui) list_ui "$1" ;;
  tap)
    xy="$(find_label "$1" "$2")"
    [ -z "$xy" ] && { echo "label not found: $2" >&2; exit 1; }
    "$ADB" -s "$1" shell input tap $xy; echo "tapped '$2' at $xy" ;;
  field)
    xy="$(list_ui "$1" | awk '$3 == "EditText" { print $1, $2; exit }')"
    [ -z "$xy" ] && { xy="$(dump_ui "$1" | python3 -c '
import re, sys, xml.etree.ElementTree as ET
for n in ET.fromstring(sys.stdin.read()).iter("node"):
    if n.get("class", "").endswith("EditText"):
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", n.get("bounds"))); print((x1 + x2) // 2, (y1 + y2) // 2); break
')"; }
    [ -z "$xy" ] && { echo "no text field visible" >&2; exit 1; }
    "$ADB" -s "$1" shell input tap $xy; echo "focused field at $xy" ;;
  type) "$ADB" -s "$1" shell input text "$(printf '%s' "$2" | sed 's/ /%s/g')" ;;
  key) "$ADB" -s "$1" shell input keyevent "KEYCODE_$2" ;;
  shot)
    f="${2:-$OT_OUT/$1.png}"
    "$ADB" -s "$1" exec-out screencap -p > "$f"; echo "$f" ;;
  wait)
    deadline=$(( $(date +%s) + ${3:-20} ))
    until [ -n "$(find_label "$1" "$2")" ]; do
      [ "$(date +%s)" -ge "$deadline" ] && { echo "timeout waiting for: $2" >&2; exit 1; }
      sleep 1
    done
    echo "visible: $2" ;;
  events) "$ADB" -s "$1" logcat -d | grep -o 'OT_TEST .*' || true ;;
  clearlog) "$ADB" -s "$1" logcat -c ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
