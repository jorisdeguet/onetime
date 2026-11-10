#!/usr/bin/env bash
# End-to-end scenario: fresh install on two phones, create + join a conversation,
# exchange a key over QR (camera of the reader pointed at the source's screen),
# then send one message in each direction and check it is decrypted.
#
# Usage: tool/testbench/scenario_exchange.sh <source-serial> <reader-serial> [key-size-label]
#   key-size-label: one of the key buttons, default "8 KB"
#
# Prints a PASS/FAIL line per check and exits non-zero on the first failure.
set -euo pipefail
OT="$(dirname "$0")/ot.sh"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
PKG="org.deguet.jo.onetime"
SRC="$1"; RDR="$2"; SIZE="${3:-8 KB}"
fail() { echo "FAIL: $*"; "$OT" shot "$SRC" >/dev/null; "$OT" shot "$RDR" >/dev/null; exit 1; }
pass() { echo "PASS: $*"; }
# Last value of a JSON field in the OT_TEST events of one device
event_field() {
  "$OT" events "$1" | sed 's/^OT_TEST //' | python3 -c '
import json, sys
event, field = sys.argv[1], sys.argv[2]
values = [json.loads(l).get(field) for l in sys.stdin if json.loads(l).get("event") == event]
print(values[-1] if values else "")
' "$2" "$3"
}
wait_event() {
  local deadline=$(( $(date +%s) + $4 ))
  until "$OT" events "$1" | grep -q "\"event\": *\"$2\".*$3"; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}
onboard() {
  "$OT" reset "$1" >/dev/null
  "$ADB" -s "$1" shell pm grant "$PKG" android.permission.CAMERA
  "$OT" clearlog "$1"
  "$OT" launch "$1"
  "$OT" wait "$1" "Commencer" 40 >/dev/null || fail "$1 login screen did not appear"
  "$OT" field "$1" >/dev/null
  "$OT" type "$1" "$2"
  "$OT" key "$1" BACK
  sleep 1
  "$OT" tap "$1" "Commencer" >/dev/null
  "$OT" wait "$1" "Rejoindre une conversation" 30 >/dev/null || fail "$1 home screen did not appear"
}
start=$(date +%s)
onboard "$SRC" "Source"
onboard "$RDR" "Reader"
pass "both phones onboarded"
"$OT" tap "$SRC" "navigation menu" >/dev/null
sleep 1
"$OT" tap "$SRC" "Create Conversation" >/dev/null
"$OT" wait "$SRC" "Valider" 30 >/dev/null || fail "conversation QR not shown on source"
pass "conversation created on source"
"$OT" tap "$RDR" "Rejoindre une conversation" >/dev/null
"$OT" wait "$RDR" "Vous avez rejoint" 40 >/dev/null || fail "reader could not scan the conversation QR (check camera alignment)"
pass "reader joined by scanning the source's screen"
sleep 2
"$OT" tap "$SRC" "Valider" >/dev/null
"$OT" wait "$SRC" "Générer une clé" 30 >/dev/null || fail "source did not reach key exchange"
"$OT" wait "$RDR" "Ou scanner une clé" 30 >/dev/null || fail "reader did not reach key exchange"
"$OT" tap "$RDR" "Ou scanner une clé" >/dev/null
sleep 2
kex_start=$(date +%s)
"$OT" tap "$SRC" "$SIZE" >/dev/null
wait_event "$SRC" key_saved "" 600 || fail "source never saved a key"
wait_event "$RDR" key_saved "" 120 || fail "reader never saved a key"
kex_secs=$(( $(date +%s) - kex_start ))
src_bytes="$(event_field "$SRC" key_saved bytes)"; rdr_bytes="$(event_field "$RDR" key_saved bytes)"
src_fp="$(event_field "$SRC" key_saved fingerprint)"; rdr_fp="$(event_field "$RDR" key_saved fingerprint)"
want_bytes=$(( ${SIZE%% *} * 1024 ))
echo "      key exchange: ${kex_secs}s, source ${src_bytes} B, reader ${rdr_bytes} B"
[ "$src_fp" = "$rdr_fp" ] || fail "key fingerprints differ ($src_fp vs $rdr_fp)"
pass "both phones hold identical key bytes ($src_fp)"
[ "$src_bytes" = "$want_bytes" ] || fail "key is $src_bytes bytes, expected $want_bytes"
pass "full requested key size kept ($want_bytes B)"
# Both phones open the conversation and introduce themselves without any tap
for s in "$SRC" "$RDR"; do
  wait_event "$s" message_sent "" 30 || fail "$s did not send its pseudo automatically"
done
wait_event "$RDR" message_decrypted "" 60 || fail "reader did not decrypt the source's pseudo"
wait_event "$SRC" message_decrypted "" 60 || fail "source did not decrypt the reader's pseudo"
pass "pseudos exchanged and decrypted"
send_and_check() {
  local from="$1" to="$2" text="$3"
  "$OT" field "$from" >/dev/null
  "$OT" type "$from" "$text"
  "$OT" key "$from" ENTER
  wait_event "$from" message_sent "\"text\": *\"$text\"" 30 || fail "$from did not send '$text'"
  wait_event "$to" message_decrypted "\"text\": *\"$text\"" 60 || fail "$to did not decrypt '$text'"
  pass "'$text' sent and decrypted"
}
send_and_check "$SRC" "$RDR" "ping-$RANDOM"
send_and_check "$RDR" "$SRC" "pong-$RANDOM"
echo "ALL PASSED in $(( $(date +%s) - start ))s"
