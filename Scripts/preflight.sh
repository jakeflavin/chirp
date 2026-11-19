#!/bin/zsh
# Preflight: runs the four everyday flows for real, in other apps, with real permissions and real audio.
# Needs: the Mac unlocked with the lid open, Chirp allowed Microphone, Accessibility and System Audio
# Recording, and Accessibility for whatever runs this script (it presses keys). It opens TextEdit with
# scratch files, and plays about 25 seconds of a recorded meeting out loud for the Record check.
# TextEdit itself is never quit: only the scratch documents opened here are closed at the end (macOS asks
# once to let the program running this control TextEdit; if that is refused they simply stay open).
# A Chirp that is already running is stopped, because the checks need their own copy.
# Usage: Scripts/preflight.sh [path to Chirp.app]
ROOT=${0:A:h:h}
APP=${1:-$ROOT/.dd/Build/Products/Release/Chirp.app}
TMP=$(mktemp -d)
STATE=$TMP/state.json
pass=0; fail=0
# The names of the scratch documents opened in TextEdit, so only those are closed afterwards.
OPENED=()
close_scratch() {
  for name in $OPENED; do
    osascript -e "tell application \"TextEdit\" to close (every document whose name is \"$name\") saving no" >/dev/null 2>&1
  done
  OPENED=()
}

# Tidy up however the script ends: the scratch folder, and the lock in CHIRP_LOCK if it was taken here.
LOCK=$CHIRP_LOCK
HELD=0
cleanup() {
  close_scratch
  rm -rf "$TMP"
  [ $HELD -eq 1 ] && rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT
# CHIRP_LOCK, when set, is a folder used as a lock so heavy jobs (builds, these checks) run one at a time.
# If it is free, it is held for the run. If it is taken, it may be the caller's own (a script that built
# the app and now runs this), so say so and carry on.
if [ -n "$LOCK" ]; then
  mkdir -p "${LOCK:h}" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then HELD=1; else echo "note: the lock $LOCK is already held; carrying on"; fi
fi
echo "load: $(uptime | sed 's/.*load averages*: //'), swap: $(sysctl -n vm.swapusage | sed 's/ *(encrypted)//')"

stop_running() { if pgrep -x Chirp >/dev/null; then echo "Stopping the running Chirp"; pkill -x Chirp; fi; }
launch() { stop_running; sleep 1; open -n "$APP" --args --debug-hooks --ui-testing --skip-onboarding "$@"; sleep 3; }
cmd() { open -g "chirp://debug/$1"; }
state() { rm -f $STATE; cmd "state?path=$STATE"; sleep 1; }
waitfor() { for i in $(seq 1 ${2:-60}); do state; [ "$(value "bool($1)")" = "True" ] && return 0; done; echo "  timed out waiting for: $1"; return 1; }
value() { python3 -c "import json,sys; d=json.load(open('$STATE')); print(eval(sys.argv[1]))" "$@" 2>/dev/null; }
check() { state
  if [ "$(value "bool($2)")" = "True" ]; then pass=$((pass+1)); echo "ok    $1"; else fail=$((fail+1)); echo "FAIL  $1"; [ -n "$3" ] && echo "      $(value "$3")"; fi }
textedit() { local name="chirp-preflight-$1-$$.txt"; printf '%s' "$2" > "$TMP/$name"; OPENED+=("$name"); open -e "$TMP/$name"; sleep 3; }

swiftc -O $ROOT/Scripts/keys.swift -o $TMP/keys 2>/dev/null || { echo "could not build the key helper"; exit 1; }

echo "== Permissions"
launch --feed-audio $ROOT/Fixtures/dictation1.wav
waitfor "'loaded' in str(d['models'].get('transcription'))" 120
check "Chirp has Accessibility" "d['accessibility']"
check "Chirp has the microphone" "d['microphone']"

echo "== Speak: hold the shortcut in TextEdit, text is typed there"
textedit speak ""
check "TextEdit is in front" "d['frontApp'] == 'com.apple.TextEdit'" "d['frontApp']"
$TMP/keys hold 49 opt 2
waitfor "len(d['dictation']['dictations']) == 1 and d['dictation']['phase'] == 'idle'" 60
check "the shortcut started and finished a dictation" "len(d['dictation']['dictations']) == 1"
sleep 2
check "the words arrived in TextEdit" "'Friday' in d['underlines']['fieldText']" "d['underlines']['status'] + ' | ' + d['underlines']['fieldText'][:80] + ' | ' + d['toast']"

echo "== Write: misspellings in TextEdit are underlined and can be fixed"
textedit write "I beleive this sentance has a few mispelled words."
waitfor "d['underlines']['count'] >= 2" 20
check "misspellings are underlined" "d['underlines']['count'] >= 2 and 'beleive' in d['underlines']['words']" "d['underlines']['status']"
echo "      underline rectangles (x, y, width, height): $(value "d['underlines']['rects']")"
cmd "underline-apply?index=0"; sleep 2
check "applying a fix changes the text in TextEdit" "'believe' in d['underlines']['fieldText']" "d['underlines']['fieldText'][:80]"
check "the fix-sentence hint is offered at the cursor" "d['sentenceFix']['available'] and d['sentenceFix']['owner'] == 'other'" "d['sentenceFix']"
$TMP/keys tap 3 ctrl,opt; sleep 2.5
check "the shortcut fixes the whole sentence in TextEdit" "'sentence' in d['underlines']['fieldText'] and 'misspelled' in d['underlines']['fieldText']" "d['underlines']['fieldText'][:80]"

echo "== Read: select text in TextEdit, press the shortcut, it is read aloud"
launch --muted-device-audio
textedit read "Chirp is reading this sentence from another app. This is the second sentence."
$TMP/keys tap 0 cmd; sleep 0.5
$TMP/keys tap 15 ctrl,opt
waitfor "d['read']['selection'] and d['read']['audioPlaying'] and d['read']['time'] > 0.3" 40
check "the selection is being played through the sound output" "d['read']['audioPlaying'] and d['read']['time'] > 0.3" "d['toast']"
check "it was not added to the library" "len(d['read']['documents']) == 0"
$TMP/keys tap 15 ctrl,opt; sleep 1.5
check "pressing the shortcut again stops it" "not d['read']['playing']"

echo "== Record: microphone and call audio are both captured, notes appear when it stops"
launch
waitfor "'loaded' in str(d['models'].get('transcription'))" 120
cmd "meeting-offer?app=us.zoom.xos"; sleep 1
check "the offer to record appears" "d['detector']['offering'] == 'us.zoom.xos'"
cmd "meeting-start"; sleep 2
afplay $ROOT/Fixtures/meeting-them.wav & PLAYER=$!
sleep 26; kill $PLAYER 2>/dev/null
check "the call side is transcribed live" "any(l.startswith('Them') for l in d['meeting']['live'])" "d['meeting']['warning']"
check "no capture warning" "d['meeting']['warning'] == ''" "d['meeting']['warning']"
cmd "meeting-stop"
waitfor "d['meeting']['phase'] == 'idle' and d['meeting']['count'] == 1" 300
check "notes were written" "len(d['meeting']['summary']) > 40"
check "the perch says the notes are ready" "'notes are ready' in d['toast'] or 'notes are ready' in d['perch']['notice']"

pkill -x Chirp
close_scratch
echo; echo "$pass passed, $fail failed. Details of each run: ~/Library/Logs/Chirp/chirp.log"
if [ $fail -eq 0 ] && [ $pass -gt 0 ]; then exit 0; else exit 1; fi
