#!/bin/zsh
# End-to-end checks: drives the built app through chirp://debug links with recorded audio
# (no microphone, screen-recording or automation permission needed) and asserts on its state.
# Usage: Scripts/e2e.sh [path to Chirp.app]   — run after a Release build.
ROOT=${0:A:h:h}
APP=${1:-$ROOT/.dd/Build/Products/Release/Chirp.app}
TMP=$(mktemp -d)
STATE=$TMP/state.json
pass=0; fail=0

# Tidy up however the script ends: the scratch folder, and the lock in CHIRP_LOCK if it was taken here.
LOCK=$CHIRP_LOCK
HELD=0
cleanup() {
  [ -n "$APP" ] && pkill -f "$TMP/e2e/Chirp.app/Contents/MacOS/Chirp" 2>/dev/null
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

# The checks run in a copy of the app with its own bundle id, so the installed Chirp keeps running, its
# settings are not touched, and links reach the copy (a bare chirp:// link goes to the installed app).
SRC=$APP
APP=$TMP/e2e/Chirp.app
mkdir -p $TMP/e2e && ditto "$SRC" "$APP" || { echo "could not copy $SRC"; exit 2; }
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.jakeflavin.chirp.e2e" "$APP/Contents/Info.plist"
codesign -f -s - --deep "$APP" >/dev/null 2>&1 || { echo "could not sign the copy"; exit 2; }
stop_running() { pkill -f "$APP/Contents/MacOS/Chirp" 2>/dev/null; }
launch() { stop_running; sleep 1; open -g -n "$APP" --args --debug-hooks --ui-testing --skip-onboarding --no-global-shortcuts "$@"; sleep 2; }
# The same, with settings in the copy's environment first (each as NAME=value), then `--`, then its flags.
launch_env() { local envs=(); while [ "$1" != "--" ]; do envs+=(--env "$1"); shift; done; shift; stop_running; sleep 1; open -g -n "$APP" $envs --args --debug-hooks --ui-testing --skip-onboarding --no-global-shortcuts "$@"; sleep 2; }
cmd() { open -g -a "$APP" "chirp://debug/$1"; }
state() { rm -f $STATE; cmd "state?path=$STATE"; sleep 1; }
waitfor() { for i in $(seq 1 ${2:-90}); do state; grep -qE "$1" $STATE 2>/dev/null && return 0; done; echo "  timed out waiting for: $1"; return 1; }
value() { python3 -c "import json,sys; d=json.load(open('$STATE')); print(eval(sys.argv[1]))" "$@" 2>/dev/null; }
# Like waitfor, but on a python expression over d, so it cannot match the same key in another section.
waitval() { for i in $(seq 1 ${2:-90}); do state; [ "$(value "bool($1)")" = "True" ] && return 0; done; echo "  timed out waiting for: $1"; return 1; }
# A check waits for what it looks for: links are answered when macOS gets to them, and on a loaded Mac
# the fixed pause before a check is not always enough. It reads the state until the expression holds, for up
# to CHECK_WAIT seconds (10), so a slow Mac makes a run slower, not red. The pause before it stays as the
# least time an action is given (a check that something did not happen still looks after that pause).
check() { # name, python expression over d that must be truthy
  local ok=0
  for i in $(seq 1 ${CHECK_WAIT:-10}); do state; [ "$(value "bool($2)")" = "True" ] && { ok=1; break; }; done
  if [ $ok -eq 1 ]; then pass=$((pass+1)); echo "ok    $1"; else fail=$((fail+1)); echo "FAIL  $1"
    python3 -c "
import json,sys
d=json.load(open('$STATE'))
print('      ', {k: v for k, v in d.items() if (\"d['\" + k + \"']\") in sys.argv[1]})" "$2"; fi
}
# Waits until the dictation itself is idle (other parts of the state also have a "phase").
dictation_idle() { for i in $(seq 1 ${1:-120}); do state; [ "$(value "d['dictation']['phase'] == 'idle'")" = "True" ] && return 0; done; echo "  timed out waiting for the dictation to finish"; return 1; }
check_file() { for i in $(seq 1 ${CHECK_WAIT:-10}); do [ -s "$2" ] && break; sleep 1; done; if [ -s "$2" ]; then pass=$((pass+1)); echo "ok    $1"; else fail=$((fail+1)); echo "FAIL  $1"; fi; }
dictate() { cmd "dictate?target=${1:-inApp}${2}"; sleep 1.5; cmd stop; sleep 1; dictation_idle 120; }

# ONLY=speak|record|notes|write|read|documents|remember|home limits the run to one section.
case "$ONLY" in
  ""|speak|record|notes|write|read|documents|remember|home|summaries) ;;
  *) echo "ONLY must be one of speak, record, notes, write, read, documents, remember, home, summaries (got: $ONLY)"; exit 2 ;;
esac
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

if want speak; then
echo "== Speak: cleanup"
launch --feed-audio $ROOT/Fixtures/dictation1.wav
waitfor '"transcription" : "loaded' 120
dictate
check "dictation is saved to history" "len(d['dictation']['dictations']) == 1"
check "filler words removed" "' um' not in d['dictation']['lastText'].lower()"
check "self-correction keeps only Friday" "'Friday' in d['dictation']['lastText'] and 'Thursday' not in d['dictation']['lastText']"
check "transcription is faster than real time" "0 < d['dictation']['seconds'] < 11"
cmd "transcribe?path=$ROOT/Fixtures/dictation1.wav"; sleep 2; dictation_idle 60
check "a transcribed audio file is a document, not a voice note" "len(d['dictation']['voiceNotes']) == 0 and len(d['documents']['transcribed']) == 1 and 'Friday' in d['documents']['transcribed'][0]['text'] and d['documents']['transcribed'][0]['format'] == 'Audio'"
check "and no notes are written for it" "d['documents']['transcribed'][0]['summary'] == '' and d['documents']['transcribed'][0]['lines'] >= 1"
check "a transcribed audio file is a document, never a voice note or a meeting" "d['dictation']['voiceNotes'] == [] and d['meeting']['count'] == 0 and d['meeting']['imported']['kind'] == 'document' and 'Friday' in d['meeting']['imported']['body']"
check "it keeps its lines and its sound, and nothing is written about it" "d['meeting']['imported']['lines'] >= 1 and d['meeting']['imported']['audio'].endswith('.m4a') and d['meeting']['imported']['summary'] == '' and d['meeting']['imported']['speakers'] == ['Speaker 1']"

echo "== Speak: learning from a correction"
launch --feed-audio $ROOT/Fixtures/names.wav
waitfor '"transcription" : "loaded' 120
dictate
check "name is misheard at first" "'Saoirse' not in d['dictation']['lastText']"
cmd "editlast?text=Please%20ask%20Saoirse%20Okafor%20to%20deploy%20the%20new%20build%20on%20Kubernetes%20before%20the%20stand-up."
check "correcting it adds the word to the dictionary" "any('Saoirse' in w for w in d['dictation']['learned'])"
dictate
check "next dictation spells the name right" "'Saoirse Okafor' in d['dictation']['lastText']"

echo "== Speak: the hold key, the shortcut, and no language model"
launch --feed-audio $ROOT/Fixtures/dictation1.wav
waitfor '"transcription" : "loaded' 120
check "holding Right Option is how dictation starts" "d['dictation']['holdKey'] == 'rightOption' and d['dictation']['mode'] == 'toggle'"
cmd "hold-key?down=1"
check "the hold key starts listening" "d['dictation']['phase'] == 'recording'"
cmd "hold-key?chord=1"; sleep 0.5; cmd "hold-key?up=1"; sleep 1
check "a shortcut's letter drops the dictation the hold began" "d['dictation']['phase'] == 'idle' and d['dictation']['dictations'] == [] and d['dictation']['notice'] == '' and d['toast'] == ''"
cmd "hold-key?down=1"; sleep 0.3; cmd "key?down=1"; cmd "key?up=1"; sleep 0.3; cmd "hold-key?up=1"
check "the hold key and then the shortcut is hands-free too" "d['dictation']['phase'] == 'recording'"
cmd cancel; sleep 1
cmd "key?down=1"; cmd "key?up=1"
check "the shortcut is hands-free: one press starts" "d['dictation']['phase'] == 'recording'"
cmd "key?down=1"; cmd "key?up=1"; sleep 1; dictation_idle 120
check "a second press stops and the words are kept" "len(d['dictation']['dictations']) == 1 and 'Friday' in d['dictation']['lastText']"
check "dictation never loads the language model" "d['languageWorker']['starts'] == 0 and not d['models']['language'].startswith('loaded')"
cmd "features?all=0&dictate=1"; sleep 1
check "Dictate alone does not need the language model" "d['features']['needs']['language'] == False and d['features']['needs']['speech'] == True"
# The switches are kept between launches, and every section after this needs them all on.
cmd "features?all=1"
check "the keys are the right Option layout" "d['shortcuts']['keys']['recordNote'] == 'right ⌥ N' and d['shortcuts']['keys']['recordMeeting'] == 'right ⌥ M' and d['shortcuts']['keys']['readSelection'] == 'right ⌥ L' and d['shortcuts']['keys']['summarize'] == 'right ⌥ U' and d['shortcuts']['keys']['writePanel'] == 'right ⌥ I' and d['shortcuts']['keys'].get('rephrase') == 'right ⌥ K' and d['shortcuts']['keys']['openLibrary'] == 'right ⌥ O' and d['shortcuts']['keys']['pasteLast'] == 'right ⌥ P' and d['shortcuts']['tiles']['recordNote'] == '⌥N'"

fi

if want record; then
echo "== Record: a two-sided meeting"
launch --feed-audio $ROOT/Fixtures/meeting-me.wav --feed-system-audio $ROOT/Fixtures/meeting-them.wav --feed-screen $ROOT/Fixtures/screen.png
waitfor '"transcription" : "loaded' 120
cmd "perch?do=more-menu"; sleep 0.5
check "Record a meeting is in the extended area, not in the … menu" "d['perch']['extendedActions'][0] == 'meeting' and 'Record a Meeting' not in d['perch']['more']"
cmd "meeting-start?kind=meeting&title=Launch%20review"
check "it is a meeting because it was started as one" "d['meeting']['recordingKind'] == 'meeting'"
check "its row is in the Library from the start, and says it is recording" "d['meeting']['rows'][0].startswith('Launch review | Recording · 0:0')"
cmd "meeting-note?text=Ask%20about%20testers.%20Budget%20is%20mine.&at=6"; cmd "meeting-capture?at=12"; sleep 4
check "a note and a picture are kept while it runs" "len(d['meeting']['liveNotes']) == 2 and d['meeting']['liveNotes'][0] == '0:06 Ask about testers. Budget is mine.' and d['meeting']['liveNotes'][1].startswith('0:12 Picture of')"
check "live transcript shows both sides while recording" "any(l.startswith('Me:') for l in d['meeting']['live']) and any(l.startswith('Them:') for l in d['meeting']['live'])"
# Cut by voice, a line arrives a little later than when it was cut at pauses (the agreed cost).
check "live transcript keeps up" "len(d['meeting']['arrivals']) >= 4 and max(d['meeting']['arrivals']) < 9"
cmd meeting-stop; sleep 3
for i in $(seq 1 100); do state; [ "$(value "d['meeting']['phase'] == 'idle' and not d['meeting']['writing']")" = "True" ] && break; sleep 2; done
check "meeting is saved with its title" "d['meeting']['count'] == 1 and d['meeting']['title'] == 'Launch review'"
check "a recording with other people in it is a meeting" "d['meeting']['kind'] == 'meeting'"
check "transcript has my side" "'Me: Sounds good' in d['meeting']['transcript'] and 'budget numbers by Wednesday' in d['meeting']['transcript']"
check "the two remote voices are told apart" "'Speaker 1:' in d['meeting']['transcript'] and 'Speaker 2:' in d['meeting']['transcript']"
check "same voice gets the same label" "d['meeting']['transcript'].count('Speaker 1:') == 2"
check "recording is kept" "d['meeting']['audio'].endswith('.m4a')"
check "the note is saved at the time it was sent" "d['meeting']['notes'][0]['at'] == 6 and d['meeting']['notes'][0]['line'] == 'Ask about testers. Budget is mine.'"
check "the picture is saved as a note at its time" "d['meeting']['notes'][1]['at'] == 12 and d['meeting']['notes'][1]['image'].endswith('.jpg') and d['meeting']['notes'][1]['line'].startswith('Picture of')"
check "a meeting's words are not kept as a text of their own" "d['meeting']['body'] == ''"
if [ -z "$SKIP_LLM" ]; then
  check "what was typed and what the picture shows are not given to the notes" "'Kingfisher' not in d['meeting']['summary'] and 'Budget is mine' not in d['meeting']['summary']"
  check "notes are summary, key points and decisions" "all(h in d['meeting']['summary'] for h in ['## Summary', '## Key points', '## Decisions']) and d['meeting']['summary'].count('## ') == 3"
  check "notes have no action items" "'Action items' not in d['meeting']['summary'] and 'To do' not in d['meeting']['summary']"
  check "notes mention the facts" "all(w in d['meeting']['summary'] for w in ['March', 'Friday', 'Kate'])"
  check "what I took on is a key point, and mine" "'I will send' in d['meeting']['summary'].split('## Key points')[1].split('## Decisions')[0]"
fi

echo "== Record: a note to yourself"
launch --feed-audio $ROOT/Fixtures/dictation1.wav
waitfor '"transcription" : "loaded' 120
cmd "perch?do=record"
check "Record a voice note starts a voice note" "d['meeting']['recordingKind'] == 'voiceNote' and d['meeting']['phase'] == 'recording' and d['meeting']['rows'][0].startswith('New note | ')"
cmd "meeting-note?text=Check%20the%20date&at=3"; sleep 4
cmd meeting-stop; sleep 3
for i in $(seq 1 60); do state; [ "$(value "d['meeting']['phase'] == 'idle' and d['meeting']['count'] == 1")" = "True" ] && break; sleep 1; done
check "it is saved as a voice note" "d['meeting']['kind'] == 'voiceNote'"
check "it is its words as clean text" "'Friday' in d['meeting']['body'] and ' um' not in d['meeting']['body'].lower() and 'Thursday' not in d['meeting']['body'] and 'Me:' not in d['meeting']['body']"
check "nothing is written about it: no summary, no to-dos" "d['meeting']['summary'] == '' and not d['meeting']['writing']"
check "a note sent during a voice note is kept at its time too" "d['meeting']['notes'][0]['at'] == 3 and d['meeting']['notes'][0]['line'] == 'Check the date'"
check "its lines are kept for playing it back" "d['meeting']['transcript'].startswith('Me:') and 'Friday' in d['meeting']['transcript']"
check "it is named from what was said" "len(d['meeting']['title']) > 8 and not d['meeting']['title'].startswith('Voice note,')"
check "it is tidied like dictation" "' um' not in d['meeting']['transcript'].lower() and ' um' not in d['meeting']['title'].lower() and 'Thursday' not in d['meeting']['transcript']"
check "its sound is kept" "d['meeting']['audio'].endswith('.m4a')"

echo "== Record: people in the same room"
launch --feed-audio $ROOT/Fixtures/meeting-them.wav
waitfor '"transcription" : "loaded' 120
cmd "meeting-start?kind=meeting"; sleep 6
cmd meeting-stop; sleep 3
for i in $(seq 1 100); do state; [ "$(value "d['meeting']['phase'] == 'idle' and not d['meeting']['writing'] and d['meeting']['count'] == 1")" = "True" ] && break; sleep 2; done
check "two voices on one microphone are told apart" "'Speaker 1:' in d['meeting']['transcript'] and 'Speaker 2:' in d['meeting']['transcript'] and 'Me:' not in d['meeting']['transcript']"
check "it is saved as a meeting, not a voice note" "d['meeting']['kind'] == 'meeting'"

echo "== Record: nothing reads the screen, and a document"
launch --feed-audio $ROOT/Fixtures/meeting-me.wav --feed-system-audio $ROOT/Fixtures/meeting-them.wav --feed-screen $ROOT/Fixtures/screen.png
waitfor '"transcription" : "loaded' 120
cmd "meeting-start?title=Launch%20review"; sleep 1
cmd "meeting-attach?path=$ROOT/Fixtures/agenda.txt"; sleep 5
cmd meeting-stop; sleep 3
for i in $(seq 1 100); do state; [ "$(value "d['meeting']['phase'] == 'idle' and not d['meeting']['writing'] and d['meeting']['count'] == 1")" = "True" ] && break; sleep 2; done
check "the screen is not read during a recording" "'Kingfisher' not in d['meeting']['context'] and '.jpg' not in d['meeting']['context']"
check "the dropped document is kept with the recording" "'agenda.txt' in d['meeting']['context'] and 'Northwind' in d['meeting']['context']"

echo "== Record: a recording cut short comes back"
CRASH=$TMP/crash
launch --data-dir $CRASH --feed-audio $ROOT/Fixtures/meeting-me.wav --feed-system-audio $ROOT/Fixtures/meeting-them.wav
waitfor '"transcription" : "loaded' 120
cmd "calendar-fake?title=Launch%20review&attendees=Priya%20Shah,Sam%20Lee&details=Agenda%3A%20pick%20the%20launch%20date"; sleep 1
cmd "meeting-start?app=Zoom"; sleep 1
cmd "meeting-note?text=Budget%20is%20mine.&at=4"; sleep 6
check "the recording is on disk while it runs" "d['meeting']['journal']"
pkill -9 -f "$APP/Contents/MacOS/Chirp"; sleep 2
open -g -n "$APP" --args --debug-hooks --ui-testing --skip-onboarding --no-global-shortcuts --data-dir $CRASH; sleep 6
for i in $(seq 1 100); do state; [ "$(value "d['meeting']['count'] == 1 and d['meeting']['phase'] == 'idle' and not d['meeting']['writing']")" = "True" ] && break; sleep 2; done
check "the recording is saved after a crash" "d['meeting']['count'] == 1 and d['meeting']['title'] == 'Launch review'"
check "its transcript survived" "'Me: Sounds good' in d['meeting']['transcript'] and 'budget numbers by Wednesday' in d['meeting']['transcript']"
check "its sound survived" "d['meeting']['audio'].endswith('.m4a')"
check "the calendar details are kept with it" "all(w in d['meeting']['context'] for w in ['Priya Shah', 'pick the launch date', 'Zoom'])"
check "the note sent before the crash is still there, at its time" "d['meeting']['notes'][0]['at'] == 4 and d['meeting']['notes'][0]['line'] == 'Budget is mine.' and d['meeting']['kind'] == 'meeting'"
check "nothing is left behind on disk" "not d['meeting']['journal']"

echo "== Record: the Mac's own sound is not written down twice"
# The microphone hears the other side from the loudspeakers (quieter, a little late, with room noise) as well as me.
launch_env "CHIRP_RECORD_TEST=notes=0" -- --feed-audio $ROOT/Fixtures/echo-me.wav --feed-system-audio $ROOT/Fixtures/echo-them.wav
waitfor '"transcription" : "loaded' 120
cmd "meeting-start?kind=meeting"; sleep 12
state; echo "      while recording: $(value "len(d['meeting']['live'])") lines heard, $(value "d['meeting']['echoesDropped']") of the microphone's left out as this Mac's sound, $(value "len([l for l in d['meeting']['shown'] if l.startswith('Me:')])") of mine shown"
check "live, the lines that only repeat the Mac are left out" "d['meeting']['echoesDropped'] >= 3 and len(d['meeting']['shown']) == len(d['meeting']['live']) - d['meeting']['echoesDropped']"
check "live, what I said myself is still mine" "any('release notes' in l for l in d['meeting']['shown'] if l.startswith('Me:'))"
check "live, nothing the other side said shows as mine" "not any('honest date' in l or 'payments provider' in l for l in d['meeting']['shown'] if l.startswith('Me:'))"
cmd meeting-stop; sleep 3
for i in $(seq 1 60); do state; [ "$(value "d['meeting']['phase'] == 'idle' and d['meeting']['count'] == 1")" = "True" ] && break; sleep 1; done
check "saved, the same" "'honest date' not in ' '.join(l['text'] for l in d['meeting']['lines'] if l['speaker'] == 'Me') and any('release notes' in l['text'] for l in d['meeting']['lines'] if l['speaker'] == 'Me')"
launch_env "CHIRP_RECORD_TEST=notes=0,headphones=1" -- --feed-audio $ROOT/Fixtures/echo-me.wav --feed-system-audio $ROOT/Fixtures/echo-them.wav
waitfor '"transcription" : "loaded' 120
cmd "meeting-start?kind=meeting"; sleep 12
check "on headphones nothing is left out" "d['meeting']['echoesDropped'] == 0 and len(d['meeting']['live']) > 0"
cmd meeting-stop; sleep 3
for i in $(seq 1 60); do state; [ "$(value "d['meeting']['phase'] == 'idle' and d['meeting']['count'] == 1")" = "True" ] && break; sleep 1; done

echo "== Record: two jobs at once, the second waits and says so"
launch --feed-audio $ROOT/Fixtures/meeting-me.wav --feed-system-audio $ROOT/Fixtures/meeting-them.wav
waitfor '"transcription" : "loaded' 120
cmd "job-hold?name=the%20link"; sleep 0.5
cmd "meeting-start?kind=meeting&title=Design%20sync"; sleep 5
cmd meeting-stop; sleep 3
for i in $(seq 1 60); do state; [ "$(value "d['meeting']['phase'] == 'idle' and d['meeting']['count'] == 1")" = "True" ] && break; sleep 1; done
check "the meeting is saved at once, with its transcript" "d['meeting']['count'] == 1 and 'Me:' in d['meeting']['transcript'] and d['meeting']['summary'] == ''"
check "its notes wait their turn and its row says what for" "d['meeting']['notesLine'] == 'Waiting for the link to finish…' and d['jobs']['waiting'] == ['Design sync']"
check "the perch says so, with the work behind it named" "d['perch']['waiting'] == 'Waiting for the link to finish…' and d['perch']['mode'] == 'working'"
check "the menu bar says so" "d['menu']['activity'] == 'waiting' and d['menu']['line'] == 'For the link to finish · then Design sync'"
cmd "transcribe?path=$ROOT/Fixtures/dictation1.wav"; sleep 1.5
check "a file asked for meanwhile waits too, and is not turned away" "d['jobs']['waiting'] == ['Design sync', 'the file'] and d['dictation']['phase'] == 'idle'"
cmd job-cancel; sleep 1
check "Cancel takes the waiting notes out of the line and keeps the meeting" "d['meeting']['notesLine'] == '' and d['jobs']['waiting'] == ['the file'] and d['meeting']['count'] == 1 and 'Me:' in d['meeting']['transcript']"
cmd "job-hold?done=1"; sleep 2
for i in $(seq 1 60); do state; [ "$(value "d['jobs']['running'] == '' and d['jobs']['waiting'] == []")" = "True" ] && break; sleep 1; done
check "when the first job ends the waiting one runs" "d['meeting']['imported']['kind'] == 'document' and 'Friday' in d['meeting']['imported']['body'] and d['perch']['waiting'] == ''"

echo "== Record: a step of finishing that never ends does not hold the recording"
# `stall=system`: the wait for the other side's last pieces never comes back, as one did in real use.
launch_env "CHIRP_RECORD_TEST=stall=system,stepLimit=4,notes=0" -- --feed-audio $ROOT/Fixtures/meeting-me.wav --feed-system-audio $ROOT/Fixtures/meeting-them.wav
waitfor '"transcription" : "loaded' 120
cmd "meeting-start?title=Launch%20review"; sleep 5
cmd meeting-stop; STOPPED=$(date +%s)
for i in $(seq 1 45); do state; [ "$(value "d['meeting']['phase'] == 'idle' and d['meeting']['count'] == 1")" = "True" ] && break; done
echo "      saved $(( $(date +%s) - STOPPED )) s after Stop, with every step limited to 4 s"
check "the recording is saved although a step never ended" "d['meeting']['phase'] == 'idle' and d['meeting']['count'] == 1 and 'system' in d['meeting']['gaveUpOn']"
check "it has the lines there were" "'Me: Sounds good' in d['meeting']['transcript'] and 'budget numbers by Wednesday' in d['meeting']['transcript']"
check "its sound is kept, and the user is told" "d['meeting']['audio'].endswith('.m4a') and 'could not be transcribed' in d['toast']"
check "nothing is left behind on disk" "not d['meeting']['journal']"

echo "== Record: calls on the Mac"
cmd "mic-trial?channels=3"; sleep 1; state
echo "      a tone through a 3-channel microphone: loudest sample $(value "d['micTrial']['before']") the old way, $(value "round(d['micTrial']['after'], 3)") now"
check "a three-channel microphone is heard, not silence" "d['micTrial']['after'] > 0.05"
cmd "mic-trial?channels=1"
check "a one-channel microphone is as it was" "abs(d['micTrial']['after'] - d['micTrial']['before']) < 0.001 and d['micTrial']['after'] > 0.05"
cmd "call-name?id=com.apple.avconferenced"
check "what holds the microphone in a FaceTime call is known as a call" "d['micTrial']['parent'] == 'com.apple.avconferenced' and d['micTrial']['name'] in ['FaceTime', 'Phone', 'FaceTime or phone']"
cmd "call-name?id=com.apple.TelephonyUtilities"
check "and in a phone call" "d['micTrial']['parent'] == 'com.apple.avconferenced'"
# (The offer itself is taken down again within three seconds, there being no call; its title stays in `state`.)
cmd "meeting-offer?app=com.apple.avconferenced"
check "such a call is offered for recording by name" "d['detector']['offerTitle'] in ['FaceTime', 'Phone', 'FaceTime or phone']"

fi

if want write; then
echo "== Write: checks in the editor"
launch
open -g -a "$APP" "chirp://show/write"; sleep 1
cmd "write-set?text=This%20is%20an%20test%20of%20teh%20checker.%20Ask%20Zorblax%20tomorow."
check "finds grammar and spelling issues" "any(i.startswith('grammar:an:a') for i in d['write']['issues']) and any(i.startswith('spelling:teh:the') for i in d['write']['issues'])"
check "flags an unknown name" "any(i.startswith('spelling:Zorblax') for i in d['write']['issues'])"
cmd "write-set?text=The%20results%20shows%20a%20clear%20trend.%20The%20list%20of%20items%20are%20on%20the%20desk.%20Everyone%20need%20to%20sign.%20The%20school%20bus%20stops%20here."
check "noun subject and verb must agree" "any(i.startswith('grammar:shows:show') for i in d['write']['issues']) and any(i.startswith('grammar:are:is') for i in d['write']['issues']) and any(i.startswith('grammar:need:needs') for i in d['write']['issues'])"
check "a correct sentence is left alone" "not any(':stops:' in i or ':bus:' in i for i in d['write']['issues'])"
cmd "write-set?text=This%20is%20an%20test%20of%20teh%20checker.%20Ask%20Zorblax%20tomorow."; sleep 2
state; N=$(value "[i.split(':')[1] for i in d['write']['issues']].index('Zorblax')")
cmd "write-act?issue=$N&do=dictionary"; sleep 2
check "adding to the dictionary stops the flag" "not any('Zorblax' in i for i in d['write']['issues'])"
cmd write-fixall
check "fix all corrects the text" "d['write']['text'] == 'This is a test of the checker. Ask Zorblax tomorrow.'"
check "nothing left to fix" "d['write']['issues'] == []"
cmd "write-set?text=Ask%20Qwyzzle%20soon."; sleep 2
cmd "write-act?issue=0&do=dismiss"; sleep 2
check "a dismissed suggestion stays dismissed" "d['write']['issues'] == []"
cmd "write-set?text=x"; sleep 1; cmd "write-set?text=Ask%20Qwyzzle%20soon."; sleep 2
check "…even after the text is checked again" "d['write']['issues'] == []"
cmd "panel?text=Their%20going%20to%20recieve%20an%20email%20tomorow."
check "selection panel finds issues instantly" "d['panel']['open'] and d['panel']['issues'] == 3"
if [ -z "$SKIP_LLM" ]; then
  cmd "write-set?text=me%20and%20him%20will%20meets%20them%20their%20tomorrow."; sleep 1
  cmd "write-run?task=fix"
  for i in $(seq 1 60); do sleep 2; state; [ "$(value "not d['write']['busy'] and len(d['write']['result']) > 0")" = "True" ] && break; done
  check "proofread fixes what the fast checker missed" "'will meet them' in d['write']['result'] and 'meets' not in d['write']['result']"
  cmd write-accept; sleep 1
  check "accepting replaces the draft" "'will meet them' in d['write']['text'] and d['write']['result'] == ''"
  cmd "panel-run?task=formal"
  for i in $(seq 1 60); do sleep 2; state; [ "$(value "not d['panel']['busy'] and (len(d['panel']['result']) > 0 or d['panel']['refused'] != '')")" = "True" ] && break; done
  check "tone rewrite keeps the facts, or is not offered" "('email' in d['panel']['result'] and 'tomorrow' in d['panel']['result']) or (d['panel']['result'] == '' and d['panel']['refused'] != '')"
fi

echo "== Write: the sentence bird, snippets as you type, style by app"
enc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"; }
cmd panel-close
check "Fix the sentence is option and tab" "'⌥' in d['sentenceFix']['keys'] and '⇥' in d['sentenceFix']['keys']"
check "and is not claimed while nothing is on offer" "not d['sentenceFix']['available'] and not d['sentenceFix']['claimed']"
# A snippet saved from selected text: More asks only for the cue.
ADDRESS=$(enc '14 Alder Lane, Portland, OR 97214')
cmd "more-menu?app=com.apple.mail&name=Mail&selected=$ADDRESS"
check "More has Save as a Snippet and the style of the app in front" "'Save as a Snippet…' in d['more']['rows'] and 'Style in Mail: Neutral' in d['more']['rows'] and d['more']['style'][:3] == ['Casual', '✓ Neutral', 'Formal']"
cmd "more-menu?app=com.apple.mail&name=Mail"
check "Save as a Snippet is greyed with nothing selected" "'Save as a Snippet… (off)' in d['more']['rows']"
cmd "more-menu?app=com.apple.mail&name=Mail&style=formal"
check "the style is changed in place" "'Style in Mail: Formal' in d['more']['rows'] and '✓ Formal' in d['more']['style']"
cmd "more-menu?app=com.apple.mail&name=Mail&do=snippet&selected=$ADDRESS"
check "the perch asks for the cue" "d['panel']['open'] and d['panel']['snippet'].startswith('14 Alder Lane') and d['perch']['content'] == 'rephrase'"
cmd "panel-snippet?save=1"; sleep 0.5
check "nothing is saved without a cue" "d['panel']['snippet'] != '' and d['panel']['snippetProblem'] != ''"
cmd "panel-snippet?cue=$(enc 'my address')&save=1"; sleep 1
check "saving it closes the question" "not d['panel']['open'] and d['panel']['snippet'] == ''"
# Typed, the cue is offered like a fix; the bird marks each sentence with something to fix.
cmd "underline-seed?app=Mail&text=$(enc 'I recieved the plan and it look good to me. I can make Tuesdays from January. Send the kit list to my address and I will sort teh rest.')"
check "a typed cue is offered" "d['offers']['snippets'] == ['my address']"
check "two sentences have a fix, the clean one has none" "len(d['offers']['sentences']) == 2 and d['offers']['sentences'][0].startswith('I recieved') and d['offers']['sentences'][1].startswith('Send the kit')"
check "only the sentence at the cursor gets the bird" "d['offers']['birdSentence'].startswith('Send the kit')"
check "the second sentence's fix puts the snippet in too" "d['offers']['becomes'][1] == 'Send the kit list to 14 Alder Lane, Portland, OR 97214 and I will sort the rest.'"
cmd "underline-seed?app=Mail&caret=60&text=$(enc 'I recieved the plan and it look good to me. I can make Tuesdays from January. Send the kit list to my address and I will sort teh rest.')"; sleep 1.5
check "with the cursor in the clean sentence, no bird" "d['offers']['birdSentence'] == '' and len(d['offers']['sentences']) == 2"
cmd "underline-seed?app=Mail&caret=5&text=$(enc 'I recieved the plan and it look good to me. I can make Tuesdays from January. Send the kit list to my address and I will sort teh rest.')"
check "and in the first sentence, the bird is on that one" "d['offers']['birdSentence'].startswith('I recieved')"
cmd "bird-click?index=0"
check "clicking a bird fixes its sentence and leaves the others" "d['underlines']['fieldText'].startswith('I received the plan and it look good to me. I can make') and 'teh rest' in d['underlines']['fieldText'] and len(d['offers']['sentences']) == 1"
cmd "bird-shot?path=$TMP/bird.png&hint=1&text=$(enc 'I recieved the plan and it look good to me.')"; sleep 1.5
check_file "the bird and its hint are drawn" "$TMP/bird.png"
cmd "card-shot?path=$TMP/snippet-card.png&index=0&text=$(enc 'Send the kit list to my address.')"; sleep 1.5
check_file "the snippet's card is drawn" "$TMP/snippet-card.png"
cmd underline-seed; sleep 0.5

echo "== Write: a note with one button"
cmd "underline-seed?app=Mail&text=$(enc 'I think we should move the long run to Saturday for the first eight weeks, because the track is closed on Sundays until March and most of the group would rather keep one full day free at the weekend, and then we can look at it again once the evenings are lighter and the track is open.')"
check "a long sentence's note has one button" "'Shorten this sentence' in d['offers']['buttons']"
if [ -z "$SKIP_LLM" ]; then
  state; N=$(value "d['offers']['buttons'].index('Shorten this sentence')"); WAS=$(value "len(d['underlines']['fieldText'])")
  cmd "note-rewrite?index=$N"
  for i in $(seq 1 60); do sleep 2; state; [ "$(value "d['offers']['note'] in ('ready', 'failed')")" = "True" ] && break; done
  check "the button rewrites the sentence, or says plainly that it could not" "(d['offers']['note'] == 'ready' and 0 < len(d['offers']['noteText']) < $WAS and d['offers']['noteSummary'].startswith('Shortened from 57 words to')) or (d['offers']['note'] == 'failed' and 'could not' in d['offers']['noteText'])"
  state
  if [ "$(value "d['offers']['note'] == 'ready'")" = "True" ]; then
    # Links are delivered by macOS when it gets to them: on a loaded Mac a second is not always enough,
    # so each step here waits for what it did to show before the next is sent.
    cmd note-accept; waitval "d['offers']['note'] == ''" 20
    check "Replace puts the shorter sentence in" "0 < len(d['underlines']['fieldText']) < $WAS and 'Saturday' in d['underlines']['fieldText'] and d['offers']['note'] == ''"
  fi
fi
cmd underline-seed; sleep 1

if [ -z "$SKIP_LLM" ]; then
  echo "== Write: a rewrite never answers the text or changes the person, and Write out adds nothing"
  # A real case: Shorten answered the question and turned I into You.
  cmd "panel?text=$(enc 'How do I make an expenses claim? I need to get paid back for my hotel and flight.')"; waitval "d['panel']['open'] and d['panel']['text'].startswith('How do I make') and not d['panel']['busy']" 20
  cmd "panel-run?task=shorten"; waitval "d['panel']['task'] == 'Shorten'" 20
  for i in $(seq 1 90); do sleep 2; state; [ "$(value "not d['panel']['busy'] and (len(d['panel']['result']) > 0 or d['panel']['refused'] != '')")" = "True" ] && break; done
  check "Shorten keeps the question and the person, or is not offered" "('?' in d['panel']['result'] and ' I ' in ' ' + d['panel']['result'] and 'You ' not in d['panel']['result']) or (d['panel']['result'] == '' and d['panel']['refused'] != '')"
  echo "      $(value "'offered: ' + d['panel']['result'] if d['panel']['result'] else 'not offered: ' + d['panel']['refused'] + ' ' + str(d['panel']['problems'])")"
  cmd "panel?text=$(enc '- flight to Denver $412, booked it myself
- hotel two nights, $380
- need it paid back before the 30th')"; waitval "d['panel']['open'] and d['panel']['text'].startswith('- flight') and d['panel']['task'] == ''" 20
  cmd "panel-run?task=writeout"; waitval "d['panel']['task'] == 'Write out'" 20
  for i in $(seq 1 90); do sleep 2; state; [ "$(value "not d['panel']['busy'] and (len(d['panel']['result']) > 0 or d['panel']['refused'] != '')")" = "True" ] && break; done
  check "Write out is the chip in Expand's place" "d['panel']['task'] == 'Write out'"
  check "Write out keeps every number and adds no greeting, or is not offered" "('412' in d['panel']['result'] and '380' in d['panel']['result'] and '30th' in d['panel']['result'] and not d['panel']['result'].lower().startswith(('hi', 'hello', 'dear'))) or (d['panel']['result'] == '' and d['panel']['refused'] != '')"
  echo "      $(value "'offered: ' + d['panel']['result'] if d['panel']['result'] else 'not offered: ' + d['panel']['refused'] + ' ' + str(d['panel']['problems'])")"
  cmd "panel-snippet"; waitval "d['panel']['snippet'] != ''" 20
  check "Save as a snippet takes the result, or the words when there is none" "d['panel']['snippet'] != ''"
  cmd "panel-snippet?cancel=1"; waitval "d['panel']['snippet'] == ''" 20
  check "Cancel goes back to the rewrite" "d['panel']['open'] and d['panel']['snippet'] == ''"
  cmd panel-close
fi
fi

if want read; then
echo "== Read: importing documents"
launch
open -g -a "$APP" "chirp://show/read"; sleep 1
# Each import must add one document, so a file that fails cannot pass on what the one before it left showing.
n=0
for f in article.txt article.pdf article.docx article.html; do
  n=$((n+1))
  cmd "read-file?path=$ROOT/Fixtures/$f"
  check "$f imports with its text" "len(d['read']['documents']) == $n and d['read']['sentences'] >= 8 and ('songbirds' in d['read']['first'] + ' ' + d['read']['current'] or 'Birds' in d['read']['first'])"
done
cmd "read-file?path=$ROOT/Fixtures/book.epub"
check "book.epub imports chapters in order with its title" "d['read']['title'] == 'Birdsong, A Short Book' and d['read']['first'] == 'Chapter One' and d['read']['sentences'] == 5"
check "all five are in the reading list" "len(d['read']['documents']) == 5"

if [ -z "$SKIP_LLM" ]; then
  echo "== Summarize: Cancel stops it, and the next one starts at once"
  launch
  # A page of about 30,000 characters: a summary in many parts, a minute or more of work.
  LONGPAGE=$TMP/long-page.txt
  python3 -c "
t = open('$ROOT/Fixtures/article.txt').read().strip()
open('$LONGPAGE', 'w').write('\n\n'.join('Part %d. %s' % (i, t) for i in range(55)))"
  cmd "summarize-here?page=$LONGPAGE"
  waitval "d['read']['summarizing'] and d['models']['language'].startswith('loaded')" 120
  sleep 6
  check "a long summary is being written" "d['drop']['summarizing'] and d['read']['summarizing']"
  # It fills in as it goes: the overview at once, then sections in order, with how far it has got.
  check "its overview shows while the rest is written" "d['drop']['summarizing'] and len(d['drop']['draft']) > 40 and d['drop']['summary'] == ''"
  check "with a line saying which part it is on" "' of ' in d['drop']['progress']"
  cmd "drop-do?what=close"; CLOSED=$(date +%s)
  for i in $(seq 1 20); do state; [ "$(value "not d['read']['summarizing']")" = "True" ] && break; done
  echo "      the work stopped $(( $(date +%s) - CLOSED )) s after Cancel"
  check "Cancel stops the summary within ten seconds" "not d['read']['summarizing'] and not d['drop']['open'] and $(( $(date +%s) - CLOSED )) <= 10"
  # A new summary straight after a cancelled one must not be refused as "still writing another summary".
  cmd "summarize-here?page=$LONGPAGE"; sleep 2; cmd "drop-do?what=close"; sleep 1
  python3 -c "
t = open('$ROOT/Fixtures/article.txt').read().strip()
open('$TMP/short-page.txt', 'w').write('\n\n'.join([t, t.replace('birds', 'young birds')]))"
  cmd "summarize-here?page=$TMP/short-page.txt"
  # A short page is its own sentences, with no model step, so it may already be written.
  check "the next summary starts at once" "d['drop']['open'] and (d['drop']['summarizing'] or len(d['drop']['summary']) > 40)"
  waitval "d['drop']['open'] and not d['drop']['summarizing'] and len(d['drop']['summary']) > 40" 90
  check "and is written" "len(d['drop']['summary']) > 40 and not d['read']['summarizing']"
fi

echo "== Read: voice"
waitfor '"transcription" : "loaded' 120
cmd "read-roundtrip?text=The%20quick%20brown%20fox%20jumps%20over%20the%20lazy%20dog%20near%20the%20river%20bank."
for i in $(seq 1 90); do sleep 2; state; [ "$(value "len(d['read']['roundTrip']) > 0")" = "True" ] && break; done
check "the voice says what is written (speak, then transcribe)" "d['read']['roundTrip'].lower().rstrip('.') == 'the quick brown fox jumps over the lazy dog near the river bank'"
check "speech is made faster than it plays" "0 < d['read']['synthSeconds'] < d['read']['audioSeconds']"

echo "== Read: playback (silent clock)"
cmd "read-file?path=$ROOT/Fixtures/article.txt"; sleep 1
cmd read-play
waitval "d['read']['index'] >= 1" 90
check "moves on to the next sentence" "d['read']['index'] >= 1 and d['read']['playing']"
waitval "d['read']['word'][:1].isalpha()" 30
check "highlights the word being spoken" "d['read']['word'] != '' and d['read']['word'] in d['read']['current']"
cmd read-pause; sleep 1; state; W=$(value "str(d['read']['index']) + d['read']['word']"); sleep 3
check "pause holds its place" "str(d['read']['index']) + d['read']['word'] == '$W' and not d['read']['playing']"
check "position is remembered" "d['read']['position'] > 0"
cmd "read-jump?index=6"; cmd read-play
waitval "d['read']['index'] == 6" 30
check "jumping to a sentence resumes there" "d['read']['index'] == 6 and d['read']['current'].startswith('Over about 3.5 months')"

echo "== Read: Say it as"
waitval "d['read']['word'][:1].isalpha()" 30
cmd "say-it-as?open=reader"; sleep 1
check "Say it as opens on a word just spoken, and reading pauses" "d['sayItAs']['open'] and d['sayItAs']['picked'] != '' and d['sayItAs']['place'] == 'reader' and not d['read']['playing']"
check "the word the mark is on is offered and picked" "d['sayItAs']['picked'].lower() in d['read']['word'].lower() or d['read']['word'].strip('.,;:!?()\\'\"').lower() in d['sayItAs']['picked'].lower()"
check "it is the last chip, after the words before it" "d['sayItAs']['words'][-1] == d['sayItAs']['picked']"
cmd "say-it-as?save=1"; sleep 0.5
check "nothing is saved without a pronunciation" "d['sayItAs']['open'] and d['sayItAs']['problem'] != ''"
cmd "say-it-as?close=1"; sleep 1
check "closing it carries on reading" "not d['sayItAs']['open'] and d['read']['playing']"
cmd "say-it-as?open=perch"; sleep 1
check "on the perch reading pauses too" "d['sayItAs']['open'] and d['sayItAs']['place'] == 'perch' and not d['read']['playing'] and d['sayItAs']['resume'] and d['perch']['content'] == 'sayItAs' and len(d['sayItAs']['words']) >= 1"
cmd "say-it-as?pick=months&text=munths&preview=1"; sleep 1
waitval "d['sayItAs']['previews'] >= 1" 30
check "Preview speaks what was typed" "d['sayItAs']['previews'] >= 1 and d['sayItAs']['text'] == 'munths'"
cmd "say-it-as?save=1"; sleep 1
check "Save puts it in the Dictionary and closes" "not d['sayItAs']['open'] and d['sayItAs']['pronunciations'].get('months') == 'munths'"
cmd "read-jump?index=5"; cmd read-play
waitval "d['read']['index'] >= 6 and 'munths' in d['sayItAs']['lastSaid']" 60
check "and it is used from the next sentence on" "'munths' in d['sayItAs']['lastSaid']"
cmd read-stop
fi

if want documents; then
echo "== Documents: what is kept with a document"
launch
open -g -a "$APP" "chirp://show/read"; sleep 1
PAGE=$ROOT/Fixtures/documents/page
cmd "doc-keep?original=1&images=1"
cmd "read-file?path=$PAGE/pace.html"
check "a page keeps its headings, lists, quote and table" "all(d['documents']['open']['blocks'].get(k, 0) >= n for k, n in [('heading', 3), ('subheading', 1), ('paragraph', 5), ('bullet', 3), ('quote', 1), ('tableHead', 1), ('tableRow', 3)]) and d['documents']['open']['layoutFits']"
check "and its bold, italic and picture" "d['documents']['open']['spans'].get('bold', 0) == 1 and d['documents']['open']['spans'].get('italic', 0) == 1 and d['documents']['open']['images'] == 1 and d['documents']['open']['imagesOnDisk'] == 1"
check "the site's menus and scripts are left out, and the title is not repeated" "d['read']['first'].startswith('Most people who struggle') and d['documents']['open']['title'] == 'How to pace your first half marathon' and d['documents']['open']['site'] == 'Long Run Journal'"
check "the original is kept beside it" "d['documents']['open']['original'] == 'original.html' and d['documents']['open']['originalOnDisk']"
check "a table is still read a cell at a time" "d['read']['sentences'] >= 30"
cmd "read-file?path=$ROOT/Fixtures/article.pdf"
check "a PDF says its pages and keeps its file" "d['documents']['open']['format'] == 'PDF' and d['documents']['open']['pages'] >= 1 and d['documents']['open']['original'] == 'original.pdf' and d['documents']['open']['originalOnDisk'] and 'PDF' in d['documents']['open']['sourceRest'] and 'added today' in d['documents']['open']['sourceRest']"
cmd "doc-view?original=1"
check "the switch in the document's header turns to the original" "d['documents']['showOriginal']"
cmd "read-file?path=$ROOT/Fixtures/book.epub"; sleep 2
check "a newly opened document starts on its reading view" "not d['documents']['showOriginal'] and d['documents']['open']['format'] == 'EPUB' and d['documents']['open']['layoutKept']"
cmd "read-file?path=$ROOT/Fixtures/documents/rich-text.rtf"
check "a rich-text file keeps its headings, italic, lists and table" "d['documents']['open']['layoutKept'] and d['documents']['open']['spans'].get('italic', 0) >= 1 and d['documents']['open']['blocks'].get('bullet', 0) >= 2 and d['documents']['open']['blocks'].get('numbered', 0) >= 2 and d['documents']['open']['blocks'].get('tableRow', 0) + d['documents']['open']['blocks'].get('tableHead', 0) >= 2 and d['documents']['open']['blocks'].get('heading', 0) >= 1"
cmd "read-file?path=$ROOT/Fixtures/documents/markdown-note.md"; sleep 2
check "a Markdown file is shown without its marks" "d['documents']['open']['layoutKept'] and '#' not in d['read']['first'] and d['documents']['open']['blocks'].get('heading', 0) >= 1"
cmd "doc-keep?original=0&images=0"; sleep 0.5
cmd "read-file?path=$PAGE/pace.html"; sleep 2
check "with both switches off only the text and its layout are kept" "d['documents']['open']['original'] == '' and d['documents']['open']['images'] == 0 and d['documents']['open']['layoutKept'] and d['documents']['open']['blocks'].get('heading', 0) >= 3"
cmd "doc-keep?original=1&images=1"

echo "== Documents: pinned, folders, the source line"
check "documents are grouped by day, with no pinned group yet" "[g['title'] for g in d['documents']['groups']] == ['Today'] and d['documents']['subtitle'].startswith('6 documents')"
BOOK="Birdsong,%20A%20Short%20Book"
cmd "item?title=$BOOK&pin=1"
check "a pinned document leads, in a group of its own, and is on Home" "d['documents']['groups'][0]['title'] == 'Pinned' and d['documents']['groups'][0]['items'] == ['Birdsong, A Short Book'] and d['documents']['groups'][1]['title'] == 'Today' and d['documents']['pinnedOnHome'] == ['Birdsong, A Short Book']"
cmd "folder?add=Running"; cmd "folder?add=Launch"; sleep 0.5
cmd "item?title=$BOOK&folder=Launch"; cmd "item?title=rich-text&folder=Running"
check "folders are listed with what they hold" "sorted((f['name'], f['count']) for f in d['documents']['folders']) == [('Launch', 1), ('Running', 1)]"
check "a row names its folder" "any(r['title'] == 'Birdsong, A Short Book' and r['meta'].endswith('· Launch') and r['meta'].startswith('EPUB') for r in d['documents']['rows'])"
cmd "folder?rename=Launch&to=Launch%20week"; cmd "folder?open=Launch%20week"
check "a renamed folder opens with everything in it" "d['library']['section'] == 'folder' and d['documents']['openFolder'] == 'Launch week' and d['documents']['folderItems'] == ['Birdsong, A Short Book']"
cmd "folder?delete=Launch%20week"; sleep 1
check "deleting a folder keeps what was in it" "[f['name'] for f in d['documents']['folders']] == ['Running'] and any(r['title'] == 'Birdsong, A Short Book' and 'Launch' not in r['meta'] for r in d['documents']['rows']) and d['library']['section'] == 'home'"
cmd "item?title=$BOOK&pin=0"
check "All, every saved item, is first under Library in the sidebar" "d['library']['sidebar'][:2] == ['home', 'everything']"
cmd "sidebar?show=0"; sleep 1
check "the sidebar button hides the sidebar" "not d['library']['sidebarShown']"
cmd "sidebar?show=1"
check "and shows it again" "d['library']['sidebarShown']"
printf 'Most people who struggle in their first half marathon did not train too little. They ran the first third too fast. This guide is about the one decision that fixes that: what pace to hold, and when. Take your best recent time, double it and add ten minutes. That is an honest finish time for a first race.' > $TMP/page.txt
cmd "read-page?file=$TMP/page.txt&link=https://longrunjournal.invalid/pace&title=Pacing%20a%20first%20half&keep=1"; sleep 3
check "a page kept from a browser keeps its address, shown as its source" "d['documents']['open']['title'] == 'Pacing a first half' and d['documents']['open']['sourceLink'] == 'https://longrunjournal.invalid/pace' and d['documents']['open']['sourceTitle'] == 'longrunjournal.invalid' and 'saved today' in d['documents']['open']['sourceRest']"

echo "== Documents: the summary panel and copying"
cmd "item?title=How%20to%20pace%20your%20first%20half%20marathon&open=1"; sleep 1
cmd "summary-seed?title=How%20to%20pace%20your%20first%20half%20marathon&file=$PAGE/summary.md"; sleep 1
cmd "item?title=How%20to%20pace%20your%20first%20half%20marathon&open=1"; sleep 1.5
check "a summary is kept with its document, panel open" "d['documents']['open']['summary'].startswith('## The main point') and not d['documents']['open']['summaryFolded']"
cmd "summary-fold?title=How%20to%20pace%20your%20first%20half%20marathon&folded=1"
check "folded, it is one line, and stays folded" "d['documents']['open']['summaryFolded'] and d['documents']['open']['summaryLine'] == 'Run the first three miles slower than goal pace. An even effort beats time banked early.'"
cmd "copy-check?title=How%20to%20pace%20your%20first%20half%20marathon&what=summary"
check "a summary is copied as rich text, with Markdown as its plain form" "'public.html' in d['documents']['copied']['types'] and 'public.rtf' in d['documents']['copied']['types'] and d['documents']['copied']['rtfBytes'] > 100 and '<h2>The main point</h2>' in d['documents']['copied']['html'] and '<li>' in d['documents']['copied']['html'] and d['documents']['copied']['plain'].startswith('## The main point')"
cmd "copy-check?title=How%20to%20pace%20your%20first%20half%20marathon&what=document"
check "a document is copied with its headings, bold and table" "'## Pick a goal you can say out loud' in d['documents']['copied']['plain'] and '**more**' in d['documents']['copied']['plain'] and '<table>' in d['documents']['copied']['html'] and '<strong>more</strong>' in d['documents']['copied']['html']"

echo "== Documents: the place it was left"
cmd "item?title=How%20to%20pace%20your%20first%20half%20marathon&position=6"; sleep 0.5
cmd "item?title=How%20to%20pace%20your%20first%20half%20marathon&open=1"
check "a document opens at the place it was left, marked, with Continue" "d['documents']['open']['sentence'] == 6 and d['documents']['open']['leftOff'] and d['documents']['open']['continueShown']"
cmd read-play; waitval "d['read']['playing']" 60
check "carrying on reads from there, and the marker gives way to the reading marks" "d['read']['index'] >= 6 and not d['documents']['open']['leftOff'] and not d['documents']['open']['continueShown']"
cmd read-stop; sleep 1

echo "== Documents: a transcribed link"
cmd "doc-transcript?title=Designing%20calm%20software&link=https://www.youtube.com/watch?v=calm&audio=$ROOT/Fixtures/dictation1.wav&duration=2530"
check "a transcribed link is a document with its lines, speakers and sound" "d['documents']['open']['kind'] == 'document' and d['documents']['open']['transcript'] and d['documents']['open']['speakers'] == ['Speaker 1', 'Speaker 2'] and d['documents']['open']['lines'] == 6 and d['documents']['open']['audio']"
check "its source is the link, by name" "d['documents']['open']['sourceTitle'] == 'YouTube · Designing calm software' and d['documents']['open']['sourceLink'].startswith('https://www.youtube.com/') and d['documents']['open']['sourceRest'].startswith('42 min · 2 speakers · transcribed today')"
check "its row says what it is" "any(r['title'] == 'Designing calm software' and r['meta'] == 'YouTube · 42 min · 2 speakers' for r in d['documents']['rows'])"
check "it is not among the voice notes or meetings" "d['dictation']['voiceNotes'] == [] and d['documents']['open']['summary'] == ''"
cmd "link-kind?url=https://www.youtube.com/watch?v=1"
check "Add a Link sends a video to be transcribed" "d['documents']['linkKind'] == 'media'"
cmd "link-kind?url=https://longrunjournal.com/pace"
check "and a page to be read" "d['documents']['linkKind'] == 'page'"
fi

if want remember; then
echo "== Remember: search"
launch --feed-audio $ROOT/Fixtures/meeting-me.wav --feed-system-audio $ROOT/Fixtures/meeting-them.wav
waitfor '"transcription" : "loaded' 120
cmd "meeting-start?title=Launch%20review"; sleep 4; cmd meeting-stop; sleep 3
for i in $(seq 1 100); do state; [ "$(value "d['meeting']['phase'] == 'idle' and not d['meeting']['writing']")" = "True" ] && break; sleep 2; done
cmd "read-file?path=$ROOT/Fixtures/article.txt"; sleep 1
open -g -a "$APP" "chirp://show/remember"; sleep 1
cmd "search?q=budget"; sleep 2; waitfor '"searching" : false' 20
check "keyword search finds the meeting" "d['search']['results'] == ['meeting: Launch review']"
check "the matching words are marked" "'«budget»' in ' '.join(d['search']['snippets'])"
cmd "search?q=songbir"
check "searching part of a word works" "d['search']['results'] == ['document: article']"
cmd search-index; sleep 3
for i in $(seq 1 100); do state; [ "$(value "not d['search']['indexing']")" = "True" ] && break; sleep 2; done
check "everything is read for search by meaning" "d['search']['pending'] == 0 and d['search']['chunks'] >= 3"
cmd "search?q=how%20young%20animals%20pick%20up%20skills"; sleep 3
check "meaning search finds the bird article without shared words" "d['search']['results'][:1] == ['document: article']"
cmd "search?q=software%20defect%20before%20release"; sleep 3
check "meaning search finds the meeting about the payment bug" "d['search']['results'][:1] == ['meeting: Launch review']"
cmd "search?q=Who%20will%20fix%20the%20payment%20bug%3F"; sleep 3; waitfor '"searching" : false' 20
check "a question is searched like any words, and nothing is answered" "'answer' not in d['search'] and len(d['search']['results']) >= 1"
fi

if want notes; then
echo "== Notes: a note in the perch, typed and dictated into, saved, opened in the Library"
NOTESDIR=$TMP/notes; mkdir -p $NOTESDIR
launch --feed-audio $ROOT/Fixtures/dictation1.wav --data-dir $NOTESDIR; sleep 3
cmd "features?all=1"; sleep 1
check "the perch's five are Dictate, Note, Read aloud, Fix writing, Summarize; the chevron opens Record a meeting and Rephrase" "d['perch']['actions'] == ['dictate', 'note', 'read', 'fix', 'summarize'] and d['perch']['extendedActions'] == ['meeting', 'rephrase'] and not d['perch']['extended']"
cmd "perch?do=more-button"
check "a click on the chevron keeps the extended area open" "d['perch']['extended'] and d['perch']['extendedPinned']"
cmd "perch?do=more-menu"; sleep 0.5
check "its … menu has the one-off items, then Settings" "'Type the Last Dictation Again' in d['perch']['more'] and 'Library' in d['perch']['more'] and d['perch']['more'][-1] == 'Settings…' and 'Rephrase…' not in d['perch']['more']"
cmd "perch?do=more-button"; sleep 1
check "a second click closes it" "not d['perch']['extended']"
cmd "perch?do=note"; sleep 2
check "Note grows the perch into a note, with the keyboard" "d['notes']['open'] and d['perch']['content'] == 'note' and d['notes']['editor'] == ''"
cmd "note?do=type&text=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("# Kitchen shelves\nMeasure the alcove; the wall is **not square**.\n- Oak, oiled\n- Brackets `600 mm` apart"))')"
check "typing is saved as it goes, its first line the title" "d['notes']['itemID'] >= 0 and d['notes']['items'][0]['title'] == 'Kitchen shelves' and d['notes']['items'][0]['typed']"
check "the note keeps its Markdown, and its words without marks for search" "d['notes']['items'][0]['markdown'].startswith('# Kitchen shelves') and '**not square**' in d['notes']['items'][0]['markdown'] and 'not square' in d['notes']['items'][0]['body'] and '**' not in d['notes']['items'][0]['body']"
cmd "note?do=dictate&text=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("ask Sam about the brackets"))')"
check "dictated words go in at the cursor, as in Dictate" "d['notes']['editor'].rstrip().lower().endswith('sam about the brackets') and d['notes']['items'][0]['dictated']"
cmd "note?do=caret&at=2"; cmd "note?do=type&text=Ideas:%20"
check "it can be edited anywhere" "d['notes']['items'][0]['markdown'].startswith('# Ideas: Kitchen shelves') and d['notes']['items'][0]['title'] == 'Ideas: Kitchen shelves'"
check "it never loads the language model" "d['languageWorker']['starts'] == 0"
cmd "note?do=close"; sleep 2
check "closing saves it to Notes, and the bird says so" "not d['notes']['open'] and d['perch']['content'] != 'note' and d['perch']['notice'] == 'Saved to Notes' and len(d['notes']['items']) == 1"
cmd "perch?do=note"; sleep 1; cmd "note?do=close"; sleep 1
check "a note closed empty is not kept" "len(d['notes']['items']) == 1"
cmd open-main; sleep 2; cmd "open-item?kind=voiceNote&n=0"
check "the same note opens full size on the Notes page, in the same editor" "d['library']['section'] == 'notes' and d['notes']['editor'].startswith('# Ideas: Kitchen shelves')"
cmd "note-copy?n=0"
check "Copy gives the Markdown as plain text, and rich text" "d['notes']['clipboardText'].startswith('# Ideas: Kitchen shelves') and d['notes']['clipboardRTF'] and d['notes']['clipboardHTML']"
cmd "note-export?n=0&format=md&path=$TMP/note.md"; cmd "note-export?n=0&format=rtf&path=$TMP/note.rtf"; cmd "note-export?n=0&format=txt&path=$TMP/note.txt"; sleep 2
check_file "Export writes a .md file" $TMP/note.md
if head -1 $TMP/note.md | grep -q '^# Ideas: Kitchen shelves'; then pass=$((pass+1)); echo "ok    the .md file is the note's Markdown"; else fail=$((fail+1)); echo "FAIL  the .md file is the note's Markdown"; fi
if grep -q 'rtf1' $TMP/note.rtf && ! grep -q '\*\*' $TMP/note.txt; then pass=$((pass+1)); echo "ok    .rtf is rich text and .txt has no marks"; else fail=$((fail+1)); echo "FAIL  .rtf is rich text and .txt has no marks"; fi
check "exporting changes nothing in the note, and the list says it was exported" "d['notes']['items'][0]['exported'] and d['notes']['items'][0]['markdown'].startswith('# Ideas: Kitchen shelves')"

echo "== Notes: a voice note keeps its audio and opens as an editable note"
waitfor '"transcription" : "loaded' 120
cmd "perch?do=record"; sleep 6; cmd meeting-stop; sleep 3
for i in $(seq 1 60); do state; [ "$(value "d['meeting']['phase'] == 'idle' and len(d['notes']['items']) == 2")" = "True" ] && break; sleep 1; done
check "a voice note is saved to Notes with its audio, and named from its words" "d['notes']['items'][0]['audio'].endswith('.m4a') and 'Friday' in d['notes']['items'][0]['body']"
cmd "open-item?kind=voiceNote&n=0"
check "it opens as an editable note of its words" "'Friday' in d['notes']['editor']"
cmd "note?do=caret&at=0"; cmd "note?do=type&text=Plan.%20"
check "editing it keeps its audio" "d['notes']['items'][0]['markdown'].startswith('Plan. ') and d['notes']['items'][0]['audio'].endswith('.m4a')"

cmd open-main; cmd "section?name=home"
check "Home says Note for a voice note, with audio kept" "any(m.startswith('Note') and 'audio kept' in m for m in d['home']['capturedMeta']) and not any('Voice note' in m for m in d['home']['capturedMeta'])"

echo "== Notes: lists continue and end as in Apple Notes"
cmd "perch?do=note"; waitval "d['notes']['open'] and d['notes']['editor'] == ''" 20
cmd "note?do=keys&text=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("Shelves\n- oak\n"))')"
check "Return in a point starts the next one" "d['notes']['editor'] == 'Shelves\\n- oak\\n- '"
cmd "note?do=keys&text=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("- pine\n"))')"
check "typing \"- \" on the continued point does not double it" "d['notes']['editor'] == 'Shelves\\n- oak\\n- pine\\n- '"
cmd "note?do=keys&text=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("\nDone"))')"
check "Return on an empty point ends the list, with no stray marker" "d['notes']['editor'] == 'Shelves\\n- oak\\n- pine\\nDone'"
cmd "note?do=keys&text=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("\n1. cut\n"))')"
check "numbered points count on" "d['notes']['editor'].endswith('Done\\n1. cut\\n2. ')"
cmd "note?do=close"
check "closed straight after Return, the empty point is not saved as a stray marker" "not d['notes']['open'] and d['notes']['items'][0]['markdown'] == 'Shelves\\n- oak\\n- pine\\nDone\\n1. cut'"

echo "== Notes and Meetings are separate switches"
cmd "features?notes=0"; sleep 1
check "Notes off: no Note on the perch, no Notes page, no ⌥N" "'note' not in d['perch']['actions'] and 'notes' not in d['library']['sidebar'] and 'recordNote' in d['features']['shortcutsOff'] and 'meetings' in d['library']['sidebar']"
cmd "features?notes=1&meetings=0"; sleep 1
check "Meetings off: no Record a meeting, no Meetings page, no ⌥M; Notes stays" "'meeting' not in d['perch']['extendedActions'] and 'meetings' not in d['library']['sidebar'] and 'recordMeeting' in d['features']['shortcutsOff'] and 'note' in d['perch']['actions']"
cmd "features?all=1"; sleep 1

echo "== Customize Perch: the user's order is kept"
cmd "perch-arrange?put=read&in=bar&at=0"; cmd "perch-arrange?put=library&in=extended&at=0"
check "an action moved to the front, and one added to the extended area" "d['perch']['actions'][0] == 'read' and d['perch']['extendedActions'][0] == 'library'"
cmd "perch-arrange?put=snippet&in=bar&at=1"
check "a sixth on the perch moves the last one into the extended area" "len(d['perch']['actions']) == 5 and d['perch']['actions'][1] == 'snippet' and d['perch']['extendedActions'][0] == 'summarize'"
launch --data-dir $NOTESDIR; sleep 3
check "the order is saved" "d['perch']['actions'][:2] == ['read', 'snippet'] and d['perch']['extendedActions'][:2] == ['summarize', 'library']"
cmd "perch-arrange?customize=1"
check "Customize Perch opens on Settings › Perch" "d['perch']['customizing'] and d['library']['settingsTab'] == 'perch'"
cmd "perch-arrange?default=1&customize=0"; sleep 1
check "Default Set puts it back" "d['perch']['actions'] == ['dictate', 'note', 'read', 'fix', 'summarize'] and d['perch']['extendedActions'] == ['meeting', 'rephrase'] and not d['perch']['customizing']"
fi

if want home; then
echo "== Home, the menu bar, onboarding and a dropped file (no model is needed)"
HOMEDIR=$TMP/home; mkdir -p $HOMEDIR
defaults delete com.jakeflavin.chirp.e2e homeTipsDismissed 2>/dev/null; defaults delete com.jakeflavin.chirp.e2e homeTipDismissedAt 2>/dev/null
defaults delete com.jakeflavin.chirp.e2e fixesAcceptedCount 2>/dev/null; defaults delete com.jakeflavin.chirp.e2e recordIncludeMacSound 2>/dev/null
launch --data-dir $HOMEDIR; sleep 3
cmd "features?all=1"
check "the welcome line greets by the time of day and says nothing is captured yet" "d['home']['greeting'] in ['Good morning', 'Good afternoon', 'Good evening'] and d['home']['line'] == 'Nothing captured yet today.' and d['home']['subtitle'].endswith('· Nothing captured yet today.')"
check "an empty Home has no section with anything in it" "d['home']['inProgress'] == [] and d['home']['comingUp'] == '' and d['home']['folders'] == [] and d['home']['tip'] == '' and d['home']['week'] == []"
cmd "read-file?path=$ROOT/Fixtures/article.txt"
check "the line is written from the day: a document today" "d['home']['line'] == 'A document today.' and d['home']['captured'] == ['article']"
cmd "folder?add=Launch"; sleep 1; cmd "item?title=article&folder=Launch"
check "Folders lists the folder with its count and when it was last added to" "d['home']['folders'] == ['Launch | 1 item · today']"
cmd "calendar-fake?in=10&title=Design%20sync&attendees=Ana"
check "Coming up has the next meeting, how soon and with whom" "d['home']['comingUp'].startswith('Design sync | ') and d['home']['comingUp'].endswith('in 10 minutes · with Ana')"
check "and the welcome line leads with it" "d['home']['line'].startswith('Your ') and d['home']['line'].endswith('meeting starts in ten minutes.')"
cmd "home-seed?dictation=Thanks,%20talk%20soon.&times=6"; sleep 1; cmd "home-fixes?add=41"
check "a sentence dictated six times is offered as a snippet, with its button" "d['home']['tip'] == 'You have dictated “Thanks, talk soon.” six times' and d['home']['tipButton'] == 'Save as a snippet'"
check "This week counts words dictated and fixes accepted, and leaves out what is nothing" "d['home']['week'] == ['18 words dictated', '41 fixes accepted']"
cmd "home-tip?dismiss=1"; sleep 1
check "a dismissed tip goes, and nothing takes its place straight away" "d['home']['tip'] == ''"
check "dictations are left out of Captured today" "d['home']['captured'] == ['article']"
cmd "menu-bar?show=0"; sleep 2
check "the menu bar item can be switched off, and Chirp keeps running" "d['library']['showInMenuBar'] == False"
cmd "menu-bar?show=1"; sleep 2
check "and on again" "d['library']['showInMenuBar'] == True"

echo "== Home: a word corrected often is offered for the Dictionary"
cmd "home-tip?quiet=0"; cmd "home-correct?wrong=recieve&right=receive&times=5"; cmd "home-correct?wrong=kubernets&right=Kubernetes&times=2"; sleep 1
check "corrections are counted, and neither an everyday word nor a word corrected twice is offered" "d['home']['corrections'] == ['recieve > receive x5', 'kubernets > Kubernetes x2'] and 'corrected' not in d['home']['tip']"
cmd "home-correct?wrong=kubernets&right=Kubernetes"
check "corrected a third time, a name is offered for the Dictionary" "d['home']['tip'] == 'You have corrected “kubernets” to “Kubernetes” three times' and d['home']['tipButton'] == 'Add to Dictionary'"
cmd "home-tip?act=1"; sleep 1
check "Add to Dictionary adds it with the spelling it was corrected from, and that tip goes" "'Kubernetes (kubernets)' in d['home']['dictionary'] and 'corrected' not in d['home']['tip'] and d['home']['corrections'] == ['recieve > receive x5']"
cmd open-main; cmd "section?name=home"; sleep 2; cmd home-bird
check "Home's bird looks at the new row, as it does when notes are ready" "d['home']['birdLooksAtRow']"
sleep 5
check "and sits as it was a few seconds later" "not d['home']['birdLooksAtRow']"

echo "== Menu bar: the settings area follows what is being done"
cmd "menu?open=1&pin=1"
check "at rest it holds the feature switches, Show the perch and All settings" "d['menu']['situation'] == 'idle' and d['menu']['heading'] == 'Features' and d['menu']['settingsRows'] == ['features', 'perch', 'allSettings'] and d['menu']['line'] == 'Hold right ⌥ to dictate'"
check "Recent leaves dictations out" "'dictation' not in d['menu']['recentKinds'] and d['menu']['recent'] == ['article']"
check "the foot is Open Library and Quit; All settings is a row" "d['menu']['rows'][-1] == ['library', 'quit'] and d['menu']['rows'][-2] == ['settings']"
cmd "menu?do=feature.summarize"; sleep 1
check "a chip switches its feature off everywhere" "d['features']['summarize'] == False and 'tile.summarize' not in sum(d['menu']['rows'], [])"
cmd "menu?do=feature.summarize"
check "and on again" "d['features']['summarize'] == True"
cmd "menu?state=reading"
check "reading aloud: voice, speed, citation marks" "d['menu']['situation'] == 'reading' and d['menu']['heading'] == 'Settings for reading aloud' and d['menu']['settingsRows'] == ['voice', 'speed', 'citations', 'allSettings']"
WAS=$(state; value "d['menu']['citations']")
cmd "menu?do=citations"; sleep 1
check "the citation switch there is the setting itself" "d['menu']['citations'] != $WAS"
cmd "menu?do=citations"; sleep 1
cmd "menu?state=dictating"
check "dictating: microphone and the hold key" "d['menu']['settingsRows'] == ['microphone', 'holdKey', 'allSettings'] and d['menu']['holdKey'] == 'Right ⌥'"
cmd "menu?state=recording"
check "recording: microphone and this Mac's sound" "d['menu']['settingsRows'] == ['microphone', 'macSound', 'allSettings'] and d['menu']['heading'] == 'Settings for recording'"
cmd "menu?state=writing"
check "writing in an app: that app's settings" "d['menu']['situation'] == 'writing' and d['menu']['title'] == 'Checking your writing' and 'underlines' in d['menu']['settingsRows']"
cmd "menu?state=transcribing"
check "while a link is transcribed only the status row changes, with a way to stop" "d['menu']['title'] == 'Transcribing · 40%' and d['menu']['situation'] == 'idle' and d['menu']['rows'][0] == ['status.stop']"
cmd "menu?state=summarizing"
check "a summary says which part it is on" "d['menu']['title'] == 'Summarizing' and d['menu']['line'].startswith('Part 2 of 5')"
cmd "menu?state=notes"
check "while notes are written the status row has a way to stop them" "d['menu']['title'] == 'Writing notes' and d['menu']['situation'] == 'idle' and d['menu']['rows'][0] == ['status.stop']"
cmd "menu?state="; cmd "menu?open=0"; sleep 1

echo "== Onboarding: a tour and the setup"
cmd "onboarding?again=1"
check "it opens again from Settings at its first step, with ten steps" "d['onboarding']['open'] and d['onboarding']['again'] and d['onboarding']['step'] == 'features' and len(d['onboarding']['steps']) == 10 and d['onboarding']['steps'][7:9] == ['notes', 'recording']"
cmd "features?meetings=0"; sleep 1
check "a feature switched off on the first step takes its step away" "'recording' not in d['onboarding']['steps'] and 'notes' in d['onboarding']['steps'] and len(d['onboarding']['steps']) == 9 and d['onboarding']['step'] == 'features'"
cmd "features?notes=0"; sleep 1
check "Notes has its own step" "'notes' not in d['onboarding']['steps'] and len(d['onboarding']['steps']) == 8"
cmd "features?meetings=1&notes=1"; sleep 1
cmd "onboarding-do?what=next"
check "Continue goes to dictation, which is tried in place" "d['onboarding']['step'] == 'dictation'"
cmd "onboarding-do?what=next"; cmd "onboarding-do?what=next"
check "then the shortcuts and the permissions" "d['onboarding']['step'] == 'permissions'"
cmd "onboarding-do?what=back"
check "Back goes back" "d['onboarding']['step'] == 'shortcuts'"
cmd "onboarding-do?what=later"; sleep 1
check "Later closes it and resets nothing" "not d['onboarding']['open'] and d['features']['meetings'] == True and d['features']['notes'] == True and d['home']['captured'] == ['article']"

echo "== A dropped file: what it is, and nothing saved unless kept"
DOCS=$(state; value "len(d['documents']['rows']) if 'rows' in d['documents'] else -1")
cmd "file-drag?state=near&path=$ROOT/Fixtures/article.txt"; sleep 1
check "a file dragged anywhere lights the perch" "d['fileDrag']['near'] and not d['fileDrag']['over'] and not d['fileDrag']['invites']"
cmd "file-drag?state=over&path=$ROOT/Fixtures/article.txt"
check "over the perch it says what a drop does" "d['fileDrag']['invites'] and d['fileDrag']['line'] == 'Drop to read, summarize or keep'"
cmd "file-drag?state="; cmd "drop?path=$ROOT/Fixtures/article.txt"
check "dropped, it shows what the file is and its first lines" "d['drop']['open'] and d['fileDrag']['facts'].startswith('Text · ') and d['fileDrag']['facts'].endswith('to listen') and d['fileDrag']['firstLines'].startswith('“')"
check "it offers Read aloud, Summarize and Keep in Library, and is not saved" "d['fileDrag']['offers'] == ['read', 'summarize', 'keep'] and not d['fileDrag']['kept'] and not d['drop']['saved']"
cmd "drop-do?what=keep"
check "Keep in Library saves it, and Keep is no longer offered" "d['fileDrag']['kept'] and d['fileDrag']['offers'] == ['read', 'summarize']"
cmd "drop-do?what=close"; sleep 1
cmd "drop?path=$ROOT/Fixtures/book-parts.epub"
check "a dropped book says who wrote it and how it is divided" "d['fileDrag']['facts'].startswith('EPUB book · ') and d['fileDrag']['about'] == 'Ana Ruiz. 2 parts, 4 chapters. Starts at the introduction.'"
cmd "drop-do?what=close"; sleep 1
cmd "drop?path=$ROOT/Fixtures/book.epub"; sleep 2
check "a book that names neither shows its first lines" "d['fileDrag']['book'] == '' and d['fileDrag']['about'].startswith('“') and d['fileDrag']['about'] == d['fileDrag']['firstLines']"
cmd "drop-do?what=close"; sleep 1

echo "== While recording: Home's In progress, and a dropped file"
launch_env "CHIRP_RECORD_TEST=notes=0" -- --feed-audio $ROOT/Fixtures/meeting-me.wav --data-dir $HOMEDIR
waitfor '"transcription" : "loaded' 120
cmd "meeting-start?title=Launch%20review"
check "Home lists the recording under In progress, a voice note as a note" "len(d['home']['inProgress']) == 1 and d['home']['inProgress'][0].startswith('Launch review | Note · ')"
cmd "drop?path=$ROOT/Fixtures/agenda.txt"; sleep 2
check "a file dropped while recording can be attached, first of its actions, and is not attached by itself" "d['drop']['open'] and d['fileDrag']['offers'][0] == 'attach' and d['meeting']['files'] == []"
cmd "drop-do?what=attach"; sleep 1
check "Attach closes the panel" "not d['drop']['open']"
cmd meeting-stop; sleep 3
for i in $(seq 1 60); do state; [ "$(value "d['meeting']['phase'] == 'idle'")" = "True" ] && break; sleep 2; done
check "the file is kept with the saved recording" "len(d['meeting']['files']) == 1 and d['meeting']['files'][0].startswith('agenda')"
check "and nothing is in progress once it is saved" "d['home']['inProgress'] == []"

echo "== A meeting's notes can be stopped while they are written (the language model is not asked)"
# `notesHold` makes the notes step stand still first, so Stop is pressed before the model is needed.
launch_env "CHIRP_RECORD_TEST=notesHold=60" -- --data-dir $HOMEDIR; sleep 3
printf 'Priya: The provider can commit to the March rates once legal has seen the contract.\nMe: Then we need it in writing before we set a date.\nPriya: I will send it over on Thursday.\n' > $TMP/sync.txt
cmd "meeting-import?path=$TMP/sync.txt&title=Design%20sync"; sleep 1; cmd meeting-redo
check "notes being written say so on the row, with Stop" "d['meeting']['title'] == 'Design sync' and d['meeting']['notesLine'] == 'Writing notes…' and d['meeting']['notesState'] == 'writing'"
check "Home lists them under In progress" "d['home']['inProgress'] == ['Design sync | Writing notes…']"
check "the perch and the menu bar can stop them" "d['perch']['canStopNotes'] and d['perch']['working'] == 'Writing notes' and d['menu']['activity'] == 'writingNotes' and d['menu']['line'] == 'Design sync' and d['menu']['rows'][0] == ['status.stop']"
cmd "menu?do=status.stop"
for i in $(seq 1 10); do state; [ "$(value "not d['meeting']['writing']")" = "True" ] && break; sleep 1; done
check "Stop in the menu bar ends them within seconds" "not d['meeting']['writing'] and d['meeting']['notesLine'] == '' and d['meeting']['notesStopped'] and d['jobs']['running'] == '' and d['menu']['activity'] == 'ready'"
check "the meeting is kept with its transcript and no notes, and nothing is reported or announced" "d['meeting']['count'] >= 1 and d['meeting']['title'] == 'Design sync' and d['meeting']['summary'] == '' and 'Priya:' in d['meeting']['transcript'] and d['banner'] == '' and d['perch']['notice'] == '' and d['home']['inProgress'] == []"
cmd meeting-redo; sleep 2
check "Write notes starts them again" "d['meeting']['notesState'] == 'writing' and not d['meeting']['notesStopped']"
cmd meeting-notes-stop
for i in $(seq 1 10); do state; [ "$(value "not d['meeting']['writing']")" = "True" ] && break; sleep 1; done
check "and Stop on the row ends them again" "not d['meeting']['writing'] and d['meeting']['summary'] == ''"
fi

if want summaries && [ -z "$SKIP_LLM" ]; then
echo "== Summaries: ads left out, then the source's own sections in order"
launch
cmd "summarize-here?page=$ROOT/Fixtures/summaries/s01-tech-newsletter.txt"
waitval "d['drop']['open'] and not d['drop']['summarizing'] and len(d['drop']['summary']) > 40" 180
check "the title is not the newsletter's header line" "d['drop']['title'] == 'TLDR'"
check "no sponsor, header or footer line is in the summary" "not any(w in d['drop']['summary'].lower() for w in ['quillstack', 'together with', 'tracewise', 'sign up', 'view online', 'unsubscribe', 'advertise'])"
check "it opens with the first section, with no overview above it" "d['drop']['summary'].lstrip().startswith('### ')"
check "the newsletter's sections come in its order, none put together" "[l[4:] for l in d['drop']['summary'].split(chr(10)) if l.startswith('### ')][:3] == ['Big Tech & Startups', 'Science & Futuristic Technology', 'Programming, Design & Data Science'] and ' / ' not in d['drop']['summary']"
check "the stories in every section are there" "all(w in d['drop']['summary'] for w in ['Orbital', 'Postgres', 'planner'])"
cmd "drop-do?what=close"; sleep 1

echo "== Summaries: a paper keeps its sections and leaves out its front matter"
cmd "summarize-here?page=$ROOT/Fixtures/summaries/s29-paper-from-pdf.txt"
waitval "d['drop']['open'] and not d['drop']['summarizing'] and len(d['drop']['summary']) > 40" 180
check "the title is the paper's, not the journal line" "d['drop']['title'].startswith('Street Trees and Summer Night')"
check "it opens with the abstract, and the finding is the right way round" "d['drop']['summary'].lstrip().startswith('### Abstract') and 'low-income neighborhoods are' not in d['drop']['summary'].lower()"
check "no journal line, running header, author or keywords line" "not any(w in d['drop']['summary'] for w in ['Journal of Urban Health', 'Vasquez', 'Keywords', 'Correspondence'])"
cmd "drop-do?what=close"; sleep 1
echo "== Summaries: a message from Mail is named by its subject; its footer is left out; a short one is a paragraph"
cmd "summarize-here?page=$ROOT/Fixtures/summaries/s28-promo-footer-email.txt&subject=Re%3A%2020%25%20off%20your%20first%20order"
waitval "d['drop']['open'] and not d['drop']['summarizing'] and len(d['drop']['summary']) > 40" 120
check "the title is the subject, without Re:" "d['drop']['title'] == '20% off your first order'"
check "no footer, address or unsubscribe line" "not any(w in d['drop']['summary'] for w in ['do not click', '6050 Washington', 'Unsubscribe', 'You received'])"
check "a short email is one paragraph, with no headings" "'#' not in d['drop']['summary'] and chr(10)+chr(10) not in d['drop']['summary'].strip()"
cmd "drop-do?what=close"; sleep 1
# The sentence checker is used when its folder is in Chirp's Models folder, and left out (said once in the log) when not.
CHECKER="$HOME/Library/Application Support/Chirp/Models/minicheck-roberta-large"
if [ -f "$CHECKER/model.safetensors" ]; then
echo "== Summaries: with the sentence checker, points are scored after the language model is put away"
launch_env CHIRP_LOG=$TMP/checker.log --
cmd "summarize-here?page=$ROOT/Fixtures/summaries/s16-research-paper.txt"
waitval "d['drop']['open'] and not d['drop']['summarizing'] and len(d['drop']['summary']) > 40" 240
check "the summary is written, with the checker's step in the log" "'### Abstract' in d['drop']['summary'] and 'checker: ' in open('$TMP/checker.log').read()"
check "the reversal is not there" "'low-income neighborhoods are' not in d['drop']['summary'].lower()"
cmd "drop-do?what=close"; sleep 1
else
echo "== Summaries: without the sentence checker installed, the rule check alone, said once in the log"
launch_env CHIRP_LOG=$TMP/nochecker.log --
cmd "summarize-here?page=$ROOT/Fixtures/summaries/s16-research-paper.txt"
waitval "d['drop']['open'] and not d['drop']['summarizing'] and len(d['drop']['summary']) > 40" 180
check "the summary is written" "'### Abstract' in d['drop']['summary']"
check_file "the log says the checker is not there" "$TMP/nochecker.log"
check "said once, no checker step" "open('$TMP/nochecker.log').read().count('sentence checker not found') == 1 and 'checker: ' not in open('$TMP/nochecker.log').read()"
cmd "drop-do?what=close"; sleep 1
fi
fi

stop_running
echo "\n$pass passed, $fail failed"
# No checks at all is not a pass.
if [ $fail -eq 0 ] && [ $pass -gt 0 ]; then exit 0; else exit 1; fi
