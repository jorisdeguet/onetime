#!/usr/bin/env bash
# End-to-end scenario: fresh install on two phones, create + join a conversation,
# exchange a key over QR (camera of the reader pointed at the source's screen),
# then send one message in each direction and check it is decrypted.
#
# Usage: tool/testbench/scenario_exchange.sh <source-serial> <reader-serial> [key-size-label]
#   key-size-label: one of the key buttons ("256 Ko", "1 Mo", "Continu"), default "256 Ko".
#   "Continu" streams until the reader taps Terminer after OT_STOP_AFTER seconds (default 60).
#
# Optional, after the messages:
#   OT_PHOTO=1        the reader takes a photo with its camera app and sends it
#                     (quality OT_PHOTO_QUALITY, default "Large"); the source
#                     must decrypt the same bytes. Needs a key larger than the photo.
#   OT_EXTEND=<size>  extend the conversation's key with a second exchange of
#                     <size> (a key button label), then send another photo if OT_PHOTO=1
#   OT_BLUETOOTH=1    choose the Bluetooth mode before each key button (sizes
#                     "1 Mo", "8 Mo", "Continu"): one QR code, then the key over Bluetooth
#
# Prints a PASS/FAIL line per check and exits non-zero on the first failure.
set -euo pipefail
OT="$(dirname "$0")/ot.sh"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
PKG="org.deguet.jo.onetime"
SRC="$1"; RDR="$2"; SIZE="${3:-256 Ko}"
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
  "$OT" reverse "$1"  # Firebase emulator ports, used by emulator builds only
  "$ADB" -s "$1" shell pm grant "$PKG" android.permission.CAMERA
  # Bluetooth acknowledgement channel (each name exists only on some Android versions)
  for perm in BLUETOOTH_SCAN BLUETOOTH_CONNECT BLUETOOTH_ADVERTISE ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION; do
    "$ADB" -s "$1" shell pm grant "$PKG" "android.permission.$perm" 2>/dev/null || true
  done
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
# "navigation menu" or "menu de navigation", depending on the phone language
"$OT" tap "$SRC" "menu" >/dev/null
sleep 1
"$OT" tap "$SRC" "Create Conversation" >/dev/null
"$OT" wait "$SRC" "Valider" 30 >/dev/null || fail "conversation QR not shown on source"
pass "conversation created on source"
"$OT" tap "$RDR" "Rejoindre une conversation" >/dev/null
"$OT" wait "$RDR" "Vous avez rejoint" 40 >/dev/null || fail "reader could not scan the conversation QR (check camera alignment)"
pass "reader joined by scanning the source's screen"
sleep 2
"$OT" tap "$SRC" "Valider" >/dev/null
"$OT" wait "$SRC" "Afficher une clé" 30 >/dev/null || fail "source did not reach key exchange"
"$OT" wait "$RDR" "Scanner une clé" 30 >/dev/null || fail "reader did not reach key exchange"
"$OT" tap "$RDR" "Scanner une clé" >/dev/null
sleep 2
# Exchanges a key of $1 (button label) and waits for a new key_saved event on
# each phone (compared by timestamp: logcat drops old events on long runs)
exchange_key() {
  local size="$1" want_new kex_start deadline src_before rdr_before
  case "$size" in
    Continu) want_new=$(( 32 * 1024 )) ;;  # at least one block
    *Mo|*MB) want_new=$(( ${size%% *} * 1024 * 1024 )) ;;
    *) want_new=$(( ${size%% *} * 1024 )) ;;
  esac
  src_before="$(event_field "$SRC" key_saved t)"; rdr_before="$(event_field "$RDR" key_saved t)"
  kex_start=$(date +%s)
  # OT_BLUETOOTH=1: key bytes over Bluetooth (one QR code for the secret)
  if [ -n "${OT_BLUETOOTH:-}" ]; then "$OT" tap "$SRC" "Bluetooth" >/dev/null; sleep 1; fi
  "$OT" tap "$SRC" "$size" >/dev/null
  # About 7 KB/s over QR, with a wide margin
  deadline=$(( kex_start + want_new / 3000 + 180 ))
  if [ "$size" = Continu ]; then
    sleep "${OT_STOP_AFTER:-60}"
    # Back means Terminer during an exchange (the moving camera preview
    # prevents uiautomator from finding the button by its label)
    "$OT" key "$RDR" BACK
    deadline=$(( $(date +%s) + 120 ))
  fi
  until [ "$(event_field "$SRC" key_saved t)" != "$src_before" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && fail "source never saved the key ($size)"
    sleep 2
  done
  deadline=$(( $(date +%s) + 120 ))
  until [ "$(event_field "$RDR" key_saved t)" != "$rdr_before" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && fail "reader never saved the key ($size)"
    sleep 2
  done
  local secs=$(( $(date +%s) - kex_start ))
  src_bytes="$(event_field "$SRC" key_saved bytes)"; rdr_bytes="$(event_field "$RDR" key_saved bytes)"
  local src_fp rdr_fp
  src_fp="$(event_field "$SRC" key_saved fingerprint)"; rdr_fp="$(event_field "$RDR" key_saved fingerprint)"
  echo "      key exchange ($size): ${secs}s, source ${src_bytes} B, reader ${rdr_bytes} B"
  sleep 2  # the reader reports its acknowledgement counts when the exchange screen closes
  echo "      bluetooth: source $(event_field "$SRC" kex_link state), reader $(event_field "$RDR" kex_link state)," \
    "acks over bluetooth $(event_field "$RDR" kex_link_acks link), over server $(event_field "$RDR" kex_link_acks server)"
  [ "$src_fp" = "$rdr_fp" ] || fail "key fingerprints differ ($src_fp vs $rdr_fp)"
  pass "both phones hold identical key bytes ($src_fp)"
  [ "$src_bytes" -ge "$want_new" ] || fail "key is $src_bytes bytes, expected at least $want_new"
  pass "requested key size kept ($want_new B new)"
}
exchange_key "$SIZE"
# Both phones open the conversation and introduce themselves without any tap
for s in "$SRC" "$RDR"; do
  wait_event "$s" message_sent "" 30 || fail "$s did not send its pseudo automatically"
done
wait_event "$RDR" message_decrypted "" 60 || fail "reader did not decrypt the source's pseudo"
wait_event "$SRC" message_decrypted "" 60 || fail "source did not decrypt the reader's pseudo"
pass "pseudos exchanged and decrypted"
send_and_check() {
  local from="$1" to="$2" text="$3"
  # The phone may still be busy saving a large key
  "$OT" wait "$from" "Envoyer image/fichier" 60 >/dev/null || fail "$from shows no conversation"
  "$OT" field "$from" >/dev/null || fail "$from: could not focus the message field"
  "$OT" type "$from" "$text"
  "$OT" key "$from" ENTER
  wait_event "$from" message_sent "\"text\": *\"$text\"" 30 || fail "$from did not send '$text'"
  wait_event "$to" message_decrypted "\"text\": *\"$text\"" 60 || fail "$to did not decrypt '$text'"
  pass "'$text' sent and decrypted"
}
send_and_check "$SRC" "$RDR" "ping-$RANDOM"
send_and_check "$RDR" "$SRC" "pong-$RANDOM"

# The reader photographs whatever its camera sees (the source's screen) and
# sends it from the gallery; the source must decrypt the same bytes.
send_photo() {
  local from="$1" to="$2" quality="${OT_PHOTO_QUALITY:-Large}" photo fp sent
  "$ADB" -s "$from" shell am start -a android.media.action.STILL_IMAGE_CAMERA >/dev/null
  sleep 4
  "$ADB" -s "$from" shell input keyevent KEYCODE_CAMERA
  sleep 3
  photo="$("$ADB" -s "$from" shell ls -t /sdcard/DCIM/Camera | head -1 | tr -d '\r')"
  "$ADB" -s "$from" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
  sleep 3
  "$OT" tap "$from" "Envoyer image/fichier" >/dev/null || fail "$from has no attachment button"
  sleep 1
  "$OT" tap "$from" "Galerie" >/dev/null
  "$OT" wait "$from" "$photo" 40 >/dev/null || fail "$from picker does not show $photo"
  "$OT" tap "$from" "$photo" >/dev/null
  "$OT" wait "$from" "Envoyer (" 30 >/dev/null || fail "$from send screen did not appear"
  "$OT" tap "$from" "$quality" >/dev/null
  sleep 4
  sent="$(event_field "$from" media_sent t)"
  "$OT" tap "$from" "Envoyer (" >/dev/null
  local deadline=$(( $(date +%s) + 60 ))
  until [ "$(event_field "$from" media_sent t)" != "$sent" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && fail "$from did not send the photo"
    sleep 1
  done
  fp="$(event_field "$from" media_sent fingerprint)"
  wait_event "$to" media_decrypted "\"fingerprint\": *\"$fp\"" 120 || fail "$to did not decrypt the photo"
  pass "photo $photo ($(event_field "$from" media_sent bytes) B, $quality) sent and decrypted identically"
  # The send screen closes itself once the photo is sent
  "$OT" wait "$from" "Envoyer image/fichier" 20 >/dev/null || fail "$from did not return to the conversation"
}
[ "${OT_PHOTO:-}" = 1 ] && send_photo "$RDR" "$SRC"

if [ -n "${OT_EXTEND:-}" ]; then
  for s in "$SRC" "$RDR"; do
    "$OT" tap "$s" "Créer / étendre une clé" >/dev/null || fail "$s has no key button"
  done
  "$OT" wait "$SRC" "Afficher une clé" 30 >/dev/null || fail "source did not reach key extension"
  "$OT" wait "$RDR" "Scanner une clé" 30 >/dev/null || fail "reader did not reach key extension"
  "$OT" tap "$RDR" "Scanner une clé" >/dev/null
  sleep 2
  exchange_key "$OT_EXTEND"
  sleep 3
  send_and_check "$SRC" "$RDR" "after-extension-$RANDOM"
  [ "${OT_PHOTO:-}" = 1 ] && send_photo "$RDR" "$SRC"
fi
echo "ALL PASSED in $(( $(date +%s) - start ))s"
