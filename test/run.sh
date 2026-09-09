#!/usr/bin/env bash
# Tests for bin/bleat. Speech, bell, and summarizer are replaced with commands
# that record what they were given, so nothing plays audio or bills a model.
#
# Unit cases run without Herdr. The live case needs a Herdr session with this
# plugin linked and runs only with BLEATR_LIVE=1: it swaps in a test config
# (restoring yours afterwards), drives a scratch pane in a background tab
# through a real status change, and checks the plugin log.
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BLEAT="$ROOT/bin/bleat"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bleatr-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$1"
	[ $# -gt 1 ] && printf '     %s\n' "${@:2}"
}

# Fresh config/state dirs per case, plus the fake say/bell/summarizer.
setup() {
	CASE_DIR="$WORK/$1"
	mkdir -p "$CASE_DIR/config" "$CASE_DIR/state"
	export HERDR_PLUGIN_CONFIG_DIR="$CASE_DIR/config"
	export HERDR_PLUGIN_STATE_DIR="$CASE_DIR/state"
	export HERDR_PLUGIN_ROOT="$ROOT"
	export BLEATR_SKIP_HERDR=1
	export BLEATR_SAY_COMMAND="printf '%s\n' \"\$BLEATR_MESSAGE\" >> \"$CASE_DIR/said\"; printf 'say\n' >> \"$CASE_DIR/order\""
	export BLEATR_BELL_COMMAND="printf '%s\n' \"\$BLEATR_SOUND_FILE\" >> \"$CASE_DIR/bell\"; printf 'bell\n' >> \"$CASE_DIR/order\""
	export BLEATR_SUMMARY_MODEL=none
	unset BLEATR_SUMMARIZE_COMMAND BLEATR_BELL BLEATR_VOICE BLEATR_COOLDOWN_SECONDS BLEATR_NOTIFY_ON BLEATR_SUMMARY_TIMEOUT_SECONDS
	export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","workspace_label":"herdr-bleatr","tab_label":"1"}'
}

event() { # status [agent]; an empty agent stays empty, as Herdr sends it
	jq -cn --arg s "$1" --arg a "${2-claude}" \
		'{event:"pane_agent_status_changed",data:{type:"pane_agent_status_changed",pane_id:"w1:p1",workspace_id:"w1",agent_status:$s,agent:$a}}'
}

run_bleat() { # status -> stdout of bleat
	HERDR_PLUGIN_EVENT_JSON="$(event "$@")" bash "$BLEAT" 2>"$CASE_DIR/stderr"
}

said() { cat "$CASE_DIR/said" 2>/dev/null; }

# --- cases -------------------------------------------------------------------

setup ignores-working
run_bleat working >/dev/null
if [ ! -e "$CASE_DIR/said" ]; then pass "a working status is ignored"; else fail "a working status is ignored" "$(said)"; fi

setup fallback-sentence
out="$(run_bleat done)"
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ] && [ "$out" = "$(said)" ]; then
	pass "done with summary_model=none speaks the template sentence"
else
	fail "done with summary_model=none speaks the template sentence" "said: $(said)" "stdout: $out"
fi

setup blocked-sentence
run_bleat blocked codex >/dev/null
if [ "$(said)" = "Codex in herdr-bleatr is waiting for your approval or an answer." ]; then
	pass "blocked uses the approval phrasing"
else
	fail "blocked uses the approval phrasing" "$(said)"
fi

setup custom-summarizer
export BLEATR_SUMMARIZE_COMMAND="cp \"\$BLEATR_PROMPT_FILE\" \"$CASE_DIR/prompt\"; cat > \"$CASE_DIR/stdin\"; printf '  \"Claude **finished** the\nplugin.\"  \n'"
run_bleat done >/dev/null
if [ "$(said)" = "Claude finished the plugin." ]; then
	pass "summarizer output is collapsed to one clean line"
else
	fail "summarizer output is collapsed to one clean line" "$(said)"
fi
if grep -q '^Event: done' "$CASE_DIR/prompt" && grep -q '^Agent: Claude' "$CASE_DIR/prompt" && grep -q '^"Claude in herdr-bleatr"' "$CASE_DIR/prompt" &&
	grep -q '^Workspace: herdr-bleatr' "$CASE_DIR/prompt" && grep -q '^Tab: 1' "$CASE_DIR/prompt" &&
	grep -q 'No terminal output' "$CASE_DIR/prompt"; then
	pass "prompt file carries event, agent, workspace, and tab"
else
	fail "prompt file carries event, agent, workspace, and tab" "$(cat "$CASE_DIR/prompt")"
fi
if cmp -s "$CASE_DIR/prompt" "$CASE_DIR/stdin"; then
	pass "prompt is also delivered on stdin"
else
	fail "prompt is also delivered on stdin"
fi

setup codex-preset
# The codex preset's invocation was checked by hand against a real Codex CLI;
# a fake `codex` records what it is given so that shape stays put. Only the
# --output-last-message file may reach the spoken sentence: `codex exec`
# chatters on stdout while it works.
mkdir -p "$CASE_DIR/bin"
cat >"$CASE_DIR/bin/codex" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$CASE_DIR/codex-args"
cat > "$CASE_DIR/codex-stdin"
while [ \$# -gt 0 ]; do
	[ "\$1" = --output-last-message ] && printf 'Codex fixed the failing test.\n' > "\$2"
	shift
done
echo 'thinking...'
FAKE
chmod +x "$CASE_DIR/bin/codex"
export BLEATR_SUMMARY_MODEL=codex
PATH="$CASE_DIR/bin:$PATH" run_bleat done >/dev/null
case "$(cat "$CASE_DIR/codex-args" 2>/dev/null)" in
"exec --model gpt-5.6-luna --skip-git-repo-check -c model_reasoning_effort=low -c web_search=disabled --disable hooks --sandbox=read-only --color never --output-last-message "*.out)
	pass "the codex preset runs the verified codex exec invocation" ;;
*)
	fail "the codex preset runs the verified codex exec invocation" "$(cat "$CASE_DIR/codex-args" 2>/dev/null)" "$(cat "$CASE_DIR/stderr")" ;;
esac
if [ "$(said)" = "Codex fixed the failing test." ]; then
	pass "the codex preset speaks the last message, not codex's stdout"
else
	fail "the codex preset speaks the last message, not codex's stdout" "$(said)"
fi
if grep -q '^Event: done' "$CASE_DIR/codex-stdin" 2>/dev/null; then
	pass "the codex preset delivers the prompt on stdin"
else
	fail "the codex preset delivers the prompt on stdin" "$(cat "$CASE_DIR/codex-stdin" 2>/dev/null | head -n 3)"
fi
rm -f "$CASE_DIR/codex-args" "$CASE_DIR/said"
PATH="$CASE_DIR/bin:$PATH" BLEATR_MODEL_ID=gpt-5.6-sol BLEATR_COOLDOWN_SECONDS=0 run_bleat done >/dev/null
case "$(cat "$CASE_DIR/codex-args" 2>/dev/null)" in
"exec --model gpt-5.6-sol "*) pass "model_id overrides the codex preset's model" ;;
*) fail "model_id overrides the codex preset's model" "$(cat "$CASE_DIR/codex-args" 2>/dev/null)" ;;
esac

setup summarizer-fails
export BLEATR_SUMMARIZE_COMMAND="echo boom >&2; exit 1"
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ] && grep -q boom "$CASE_DIR/state/summarize.err"; then
	pass "a failing summarizer falls back to the template and logs stderr"
else
	fail "a failing summarizer falls back to the template and logs stderr" "$(said)" "$(cat "$CASE_DIR/state/summarize.err" 2>/dev/null)"
fi

setup unrecognized-agent
# Herdr sends an empty agent for a program it has no detection profile for.
# The prompt must still tell the summarizer what to call it, and the fallback
# must not say "Agent in".
export BLEATR_SUMMARIZE_COMMAND="cp \"\$BLEATR_PROMPT_FILE\" \"$CASE_DIR/prompt\"; exit 1"
run_bleat done "" >/dev/null
if [ "$(said)" = "Your agent in herdr-bleatr finished and is waiting for you." ] &&
	grep -q '^Agent: Your agent' "$CASE_DIR/prompt" && grep -q '"Your agent in herdr-bleatr"' "$CASE_DIR/prompt"; then
	pass "an unrecognized agent is called Your agent in the prompt and the fallback"
else
	fail "an unrecognized agent is called Your agent in the prompt and the fallback" "$(said)" "$(grep -n 'agent in' "$CASE_DIR/prompt")"
fi

setup omp-agent
export BLEATR_SUMMARIZE_COMMAND="cp \"\$BLEATR_PROMPT_FILE\" \"$CASE_DIR/prompt\"; exit 1"
run_bleat done omp >/dev/null
if [ "$(said)" = "OMP in herdr-bleatr finished and is waiting for you." ] && grep -q '^Agent: OMP' "$CASE_DIR/prompt"; then
	pass "the omp integration's lowercase id is spoken as OMP"
else
	fail "the omp integration's lowercase id is spoken as OMP" "$(said)"
fi

setup pi-agent
export BLEATR_SUMMARIZE_COMMAND="cp \"\$BLEATR_PROMPT_FILE\" \"$CASE_DIR/prompt\"; exit 1"
run_bleat done pi >/dev/null
if [ "$(said)" = "Pi in herdr-bleatr finished and is waiting for you." ] &&
	grep -q '^The agent is called Pi\.' "$CASE_DIR/prompt" && grep -q '"Pi in herdr-bleatr"' "$CASE_DIR/prompt"; then
	pass "the prompt names the reported agent, not one from the examples"
else
	fail "the prompt names the reported agent, not one from the examples" "$(said)" "$(grep -n 'Pi' "$CASE_DIR/prompt")"
fi

setup summarizer-hangs
export BLEATR_SUMMARIZE_COMMAND="sleep 30"
export BLEATR_SUMMARY_TIMEOUT_SECONDS=1
start=$(date +%s)
run_bleat done >/dev/null
elapsed=$(($(date +%s) - start))
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ] && [ "$elapsed" -lt 10 ]; then
	pass "a hanging summarizer is cut off at the timeout"
else
	fail "a hanging summarizer is cut off at the timeout" "said: $(said)" "elapsed: ${elapsed}s"
fi

setup max-words
# The prompt asks for at most max_words words; a model that runs on regardless
# is cut back to them, and only between words.
export BLEATR_MAX_WORDS=6
export BLEATR_SUMMARIZE_COMMAND="printf 'Claude in herdr-bleatr finished the plugin tests and wants you to review the README.\n'"
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished the plugin" ]; then
	pass "a long summary is cut to max_words whole words"
else
	fail "a long summary is cut to max_words whole words" "$(said)"
fi

setup max-words-inside-budget
export BLEATR_MAX_WORDS=25
export BLEATR_SUMMARIZE_COMMAND="printf 'Claude in herdr-bleatr fixed the parser and stopped.\n'"
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr fixed the parser and stopped." ]; then
	pass "a summary inside the budget is spoken whole"
else
	fail "a summary inside the budget is spoken whole" "$(said)"
fi

setup max-words-not-a-number
# A hand-edited config can put anything in max_words.
export BLEATR_MAX_WORDS=lots
export BLEATR_SUMMARIZE_COMMAND="printf 'Claude in herdr-bleatr fixed the parser and stopped.\n'"
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr fixed the parser and stopped." ]; then
	pass "a non-numeric max_words caps nothing"
else
	fail "a non-numeric max_words caps nothing" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi

setup max-words-template
# The cap is the summarizer's. The template sentence is already short and
# keeps its ending however small max_words is.
export BLEATR_MAX_WORDS=3
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ]; then
	pass "max_words does not cut the template sentence"
else
	fail "max_words does not cut the template sentence" "$(said)"
fi

setup speech-length-backstop
# Behind max_words, sanitize_speech stops a sentence at about 400 characters.
# That stop lands between words too: every word here is the same token, so a
# cut inside one shows up as a short last word.
export BLEATR_MAX_WORDS=9999
export BLEATR_SUMMARIZE_COMMAND="yes hedgehog | head -n 100 | tr '\\n' ' '"
run_bleat done >/dev/null
spoken="$(said)"
if [ "${#spoken}" -le 401 ] && [ "${spoken##* }" = hedgehog ]; then
	pass "an overlong sentence is stopped at a word boundary"
else
	fail "an overlong sentence is stopped at a word boundary" "length ${#spoken}, last word ${spoken##* }"
fi

setup cooldown
run_bleat done >/dev/null
run_bleat done >/dev/null
run_bleat blocked >/dev/null
if [ "$(said | wc -l | tr -d ' ')" = 2 ]; then
	pass "a repeat within the cooldown is skipped, a different status is not"
else
	fail "a repeat within the cooldown is skipped, a different status is not" "$(said)"
fi

setup stale-stamps
# in_cooldown leaves a stamp per pane and status behind and sweeps day-old
# ones on its way in. The run below is inside the cooldown -- a current stamp
# for its own pane and status is planted first -- so it sweeps and returns
# before the speech lock is taken, which is what lets the lock directory sit
# here as a decoy. `muted` is not one of the decoys: a mute file would stop
# the run before the cooldown check. The same name filter protects it as
# protects `intro-seen`.
mkdir -p "$CASE_DIR/state/speaking.lock"
date +%s >"$CASE_DIR/state/last.w1_p1-done"
: >"$CASE_DIR/state/last.w1_p9-blocked"
: >"$CASE_DIR/state/intro-seen"
: >"$CASE_DIR/state/summarize.err"
: >"$CASE_DIR/state/speaking.lock/last.inner"
touch -t 202001010000 "$CASE_DIR/state/last.w1_p9-blocked" "$CASE_DIR/state/intro-seen" \
	"$CASE_DIR/state/summarize.err" "$CASE_DIR/state/speaking.lock/last.inner"
run_bleat done >/dev/null
if [ ! -e "$CASE_DIR/state/last.w1_p9-blocked" ] && [ -e "$CASE_DIR/state/last.w1_p1-done" ]; then
	pass "a day-old cooldown stamp is swept and a current one is kept"
else
	fail "a day-old cooldown stamp is swept and a current one is kept" "$(ls "$CASE_DIR/state")"
fi
if [ -e "$CASE_DIR/state/intro-seen" ] && [ -e "$CASE_DIR/state/summarize.err" ] &&
	[ -e "$CASE_DIR/state/speaking.lock/last.inner" ]; then
	pass "the sweep leaves the state files and the speech lock alone"
else
	fail "the sweep leaves the state files and the speech lock alone" "$(find "$CASE_DIR/state")"
fi

setup sweep-best-effort
# The sweep is housekeeping: a find that fails, or is not on the machine at
# all, must not cost a notification.
mkdir -p "$CASE_DIR/bin"
printf '#!/bin/sh\nexit 3\n' >"$CASE_DIR/bin/find"
chmod +x "$CASE_DIR/bin/find"
PATH="$CASE_DIR/bin:$PATH" run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ]; then
	pass "a failing sweep still speaks"
else
	fail "a failing sweep still speaks" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi

setup mute
bash "$BLEAT" mute 2>/dev/null
run_bleat done >/dev/null
[ -e "$CASE_DIR/said" ] && fail "muted: nothing is spoken" "$(said)" || pass "muted: nothing is spoken"
bash "$BLEAT" toggle 2>/dev/null
run_bleat done >/dev/null
[ -e "$CASE_DIR/said" ] && pass "toggle unmutes" || fail "toggle unmutes"

setup active-tab
# Herdr suppresses its own popups for the tab the user is looking at. The
# event's tab comes from the invocation context; the focused tab comes from
# `herdr api snapshot`, answered here by a fake herdr.
unset BLEATR_SKIP_HERDR
cat >"$CASE_DIR/herdr" <<'FAKE'
#!/bin/sh
case "$1 $2" in
"api snapshot") printf '{"result":{"snapshot":{"focused_tab_id":"%s"}}}\n' "$FAKE_FOCUSED_TAB" ;;
*) exit 1 ;;
esac
FAKE
chmod +x "$CASE_DIR/herdr"
export HERDR_BIN_PATH="$CASE_DIR/herdr"
export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","workspace_label":"herdr-bleatr","tab_id":"w1:t1","tab_label":"1"}'
FAKE_FOCUSED_TAB=w1:t1 run_bleat blocked >/dev/null
if [ ! -e "$CASE_DIR/said" ]; then
	pass "an event in the focused tab is not spoken"
else
	fail "an event in the focused tab is not spoken" "$(said)"
fi
FAKE_FOCUSED_TAB=w1:t2 run_bleat blocked >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr is waiting for your approval or an answer." ]; then
	pass "an event in a background tab is spoken"
else
	fail "an event in a background tab is spoken" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi
rm -f "$CASE_DIR/said"
FAKE_FOCUSED_TAB=w1:t1 bash "$BLEAT" test >/dev/null 2>"$CASE_DIR/stderr"
if [ "$(said)" = "Test agent in herdr-bleatr finished and is waiting for you." ]; then
	pass "bleat test speaks even though the current pane is in the focused tab"
else
	fail "bleat test speaks even though the current pane is in the focused tab" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi
rm -f "$CASE_DIR/said"
HERDR_BIN_PATH=false run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ]; then
	pass "an event is spoken when the focused tab cannot be read"
else
	fail "an event is spoken when the focused tab cannot be read" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi
unset HERDR_BIN_PATH

setup mute-mid-flight
# The gates at the top of bleat() are old news by the time there is a sentence
# to say. A mute pressed while the model was writing still has to land, and
# without a bell either.
export BLEATR_BELL="$CASE_DIR/ding.wav"
: >"$CASE_DIR/ding.wav"
export BLEATR_SUMMARIZE_COMMAND=": > \"$CASE_DIR/state/muted\"; printf 'Claude finished the tests.\n'"
run_bleat done >/dev/null
if [ ! -e "$CASE_DIR/said" ] && [ ! -e "$CASE_DIR/bell" ]; then
	pass "a mute during the summary suppresses the sentence"
else
	fail "a mute during the summary suppresses the sentence" "$(said)" "$(cat "$CASE_DIR/bell" 2>/dev/null)"
fi

setup focus-mid-flight
# The other half of it: the user switches into the pane's tab while the model
# writes, and by the time the sentence is ready they are reading the pane. The
# fake herdr answers from a file the summarizer rewrites, which is the switch.
unset BLEATR_SKIP_HERDR
cat >"$CASE_DIR/herdr" <<FAKE
#!/bin/sh
case "\$1 \$2" in
"api snapshot") printf '{"result":{"snapshot":{"focused_tab_id":"%s"}}}\n' "\$(cat "$CASE_DIR/focused")" ;;
*) exit 1 ;;
esac
FAKE
chmod +x "$CASE_DIR/herdr"
export HERDR_BIN_PATH="$CASE_DIR/herdr"
export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","workspace_label":"herdr-bleatr","tab_id":"w1:t1","tab_label":"1"}'
printf 'w1:t2\n' >"$CASE_DIR/focused"
export BLEATR_SUMMARIZE_COMMAND="printf 'w1:t1\n' >\"$CASE_DIR/focused\"; printf 'Claude finished the tests.\n'"
run_bleat done >/dev/null
if [ ! -e "$CASE_DIR/said" ]; then
	pass "switching into the pane's tab during the summary suppresses the sentence"
else
	fail "switching into the pane's tab during the summary suppresses the sentence" "$(said)"
fi
# The same run with the user still elsewhere speaks, so it was the switch that
# silenced the one above and not the fake.
printf 'w1:t2\n' >"$CASE_DIR/focused"
export BLEATR_SUMMARIZE_COMMAND="printf 'Claude finished the tests.\n'"
BLEATR_COOLDOWN_SECONDS=0 run_bleat done >/dev/null
if [ "$(said)" = "Claude finished the tests." ]; then
	pass "a pane whose tab stays in the background is spoken"
else
	fail "a pane whose tab stays in the background is spoken" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi
unset HERDR_BIN_PATH

setup pane-closed
# The snapshot read just before speaking also says whether the pane is still
# open; one closed while the model wrote has nobody left to tell. A snapshot
# that lists no panes at all knows nothing about this one, which is why the
# fake herdr in the cases above -- it answers with a focused tab and nothing
# else -- still speaks.
unset BLEATR_SKIP_HERDR
cat >"$CASE_DIR/herdr" <<FAKE
#!/bin/sh
case "\$1 \$2" in
"api snapshot") cat "$CASE_DIR/snapshot" ;;
*) exit 1 ;;
esac
FAKE
chmod +x "$CASE_DIR/herdr"
export HERDR_BIN_PATH="$CASE_DIR/herdr"
printf '{"result":{"snapshot":{"focused_tab_id":"w1:t2","panes":[{"pane_id":"w1:p1"}]}}}\n' >"$CASE_DIR/snapshot"
run_bleat done >/dev/null
if [ -e "$CASE_DIR/said" ]; then
	pass "a pane the snapshot still lists is spoken"
else
	fail "a pane the snapshot still lists is spoken" "$(cat "$CASE_DIR/stderr")"
fi
rm -f "$CASE_DIR/said"
printf '{"result":{"snapshot":{"focused_tab_id":"w1:t2","panes":[{"pane_id":"w1:p9"}]}}}\n' >"$CASE_DIR/snapshot"
BLEATR_COOLDOWN_SECONDS=0 run_bleat done >/dev/null
if [ ! -e "$CASE_DIR/said" ]; then
	pass "a pane closed while the summary was written is not spoken"
else
	fail "a pane closed while the summary was written is not spoken" "$(said)"
fi
unset HERDR_BIN_PATH

setup bell-order
export BLEATR_BELL="$CASE_DIR/ding.wav"
: >"$CASE_DIR/ding.wav"
run_bleat done >/dev/null
if [ "$(cat "$CASE_DIR/order" | tr '\n' ' ')" = "bell say " ] && [ "$(cat "$CASE_DIR/bell")" = "$CASE_DIR/ding.wav" ]; then
	pass "the bell plays before speech"
else
	fail "the bell plays before speech" "$(cat "$CASE_DIR/order" 2>/dev/null | tr '\n' ' ')"
fi

setup bell-tilde
# The sound file goes under the real HOME rather than HOME being pointed at
# the case directory. Moving HOME breaks version-manager shims -- mise puts
# its trust state under HOME, and its `jq` shim then writes nothing, which
# leaves the event JSON empty and the case passing or failing for a reason
# that has nothing to do with `~`.
TILDE_DIR="$(mktemp -d "$HOME/.bleatr-test.XXXXXX")"
: >"$TILDE_DIR/ding.wav"
export BLEATR_BELL="~/${TILDE_DIR#"$HOME"/}/ding.wav"
run_bleat done >/dev/null
if [ "$(cat "$CASE_DIR/bell" 2>/dev/null)" = "$TILDE_DIR/ding.wav" ]; then
	pass "a leading ~ in the bell path is expanded"
else
	fail "a leading ~ in the bell path is expanded" \
		"bell: $(cat "$CASE_DIR/bell" 2>/dev/null)" "$(cat "$CASE_DIR/stderr")"
fi
rm -rf "$TILDE_DIR"

setup bell-settings-name
if [ -f /System/Library/Sounds/Glass.aiff ]; then
	export BLEATR_BELL="Crystal"
	run_bleat done >/dev/null
	if [ "$(cat "$CASE_DIR/bell" 2>/dev/null)" = "/System/Library/Sounds/Glass.aiff" ]; then
		pass "a System Settings alert name resolves to its sound file"
	else
		fail "a System Settings alert name resolves to its sound file" "$(cat "$CASE_DIR/stderr")"
	fi
else
	printf 'skip a System Settings alert name resolves to its sound file: not macOS\n'
fi

setup bell-terminal
export BLEATR_BELL=terminal
run_bleat blocked >/dev/null
if [ "$(cat "$CASE_DIR/bell" 2>/dev/null)" = "request" ] &&
	[ "$(cat "$CASE_DIR/order" | tr '\n' ' ')" = "bell say " ]; then
	pass "bell = terminal hands a blocked bell to Herdr as the request sound"
else
	fail "bell = terminal hands a blocked bell to Herdr as the request sound" \
		"$(cat "$CASE_DIR/bell" 2>/dev/null)" "$(cat "$CASE_DIR/stderr")"
fi

setup bell-terminal-no-file
# `terminal` is not a sound file, so nothing must go looking for one on disk.
export BLEATR_BELL=terminal
unset BLEATR_BELL_COMMAND
export HERDR_BIN_PATH=true
run_bleat done >/dev/null
if [ -e "$CASE_DIR/said" ] && ! grep -q "not found" "$CASE_DIR/stderr"; then
	pass "bell = terminal never searches the sound directories"
else
	fail "bell = terminal never searches the sound directories" "$(cat "$CASE_DIR/stderr")"
fi
unset HERDR_BIN_PATH

setup sanitize-shell-metacharacters
# A summarizer sentence is model-written from untrusted terminal output. It
# must not be able to smuggle code into a say_command that splices it into a
# quoted remote shell.
cat >"$CASE_DIR/evil.sh" <<'EVIL'
printf '%s\n' 'Claude $(touch PWNED) finished; rm -rf `x` the agent'"'"'s tests'
EVIL
export BLEATR_SUMMARIZE_COMMAND="sh '$CASE_DIR/evil.sh'"
# say_command splices the sentence into a nested quoted shell, the shape the
# multi-host recipes use. Nothing in it may execute.
export BLEATR_SAY_COMMAND="cd '$CASE_DIR' && sh -c \"printf '%s\\n' \\\"\$BLEATR_MESSAGE\\\" >> '$CASE_DIR/said'\""
run_bleat done >/dev/null
if [ ! -e "$CASE_DIR/PWNED" ] &&
	[ "$(said)" = "Claude touch PWNED finished rm -rf x the agents tests" ]; then
	pass "shell metacharacters are stripped from the summarizer's sentence"
else
	fail "shell metacharacters are stripped from the summarizer's sentence" \
		"said: $(said)" "pwned: $([ -e "$CASE_DIR/PWNED" ] && echo yes || echo no)"
fi

setup sanitize-fallback-title
# The fallback sentence carries the pane's terminal title, which the agent
# controls just as surely as anything the summarizer read.
titled_event="$(jq -cn --arg t '$(id) && echo' \
	'{event:"pane_agent_status_changed",data:{type:"pane_agent_status_changed",pane_id:"w1:p1",workspace_id:"w1",agent_status:"done",agent:"claude",title:$t}}')"
HERDR_PLUGIN_EVENT_JSON="$titled_event" bash "$BLEAT" >/dev/null 2>"$CASE_DIR/stderr"
case "$(said)" in
*'$'* | *'&'* | *'('*) fail "shell metacharacters are stripped from the fallback sentence" "$(said)" ;;
*) pass "shell metacharacters are stripped from the fallback sentence" ;;
esac

setup bell-missing
export BLEATR_BELL="NoSuchSound"
run_bleat done >/dev/null
if [ ! -e "$CASE_DIR/bell" ] && [ -e "$CASE_DIR/said" ] && grep -q "not found" "$CASE_DIR/stderr"; then
	pass "an unknown bell is logged and speech still happens"
else
	fail "an unknown bell is logged and speech still happens" "$(cat "$CASE_DIR/stderr")"
fi

setup config-file
unset BLEATR_SAY_COMMAND BLEATR_SUMMARY_MODEL
cat >"$CASE_DIR/config/config.toml" <<EOF
# comment line
voice = "Daniel"   # trailing comment
bell = false
summary_model = 'none'
notify_on = ["idle", "blocked"]
cooldown_seconds = 0
say_command = 'printf "%s|%s\n" "\$BLEATR_MESSAGE" "\$BLEATR_VOICE_UNUSED" >> "$CASE_DIR/said"'
EOF
run_bleat done >/dev/null
run_bleat idle >/dev/null
run_bleat idle >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr is idle.|
Claude in herdr-bleatr is idle.|" ]; then
	pass "config.toml: strings, arrays, comments, and a quoted say_command parse"
else
	fail "config.toml: strings, arrays, comments, and a quoted say_command parse" "$(said)"
fi
# Output is captured first: piping into grep -q would SIGPIPE bleat, which
# pipefail reports as a failure.
out="$(bash "$BLEAT" config 2>/dev/null)"
if printf '%s\n' "$out" | grep -q '^voice=Daniel$'; then
	pass "bleat config prints effective settings"
else
	fail "bleat config prints effective settings" "$out"
fi

setup env-overrides-file
printf 'voice = "Daniel"\n' >"$CASE_DIR/config/config.toml"
out="$(BLEATR_VOICE=Samantha bash "$BLEAT" config 2>/dev/null)"
if printf '%s\n' "$out" | grep -q '^voice=Samantha$'; then
	pass "an env var overrides config.toml"
else
	fail "an env var overrides config.toml" "$out"
fi

setup setup-creates-config
out="$(bash "$BLEAT" setup 2>/dev/null)"
if cmp -s "$ROOT/config.example.toml" "$CASE_DIR/config/config.toml" && [ "$out" = "$CASE_DIR/config/config.toml" ]; then
	pass "setup copies config.example.toml into the config dir and prints the path"
else
	fail "setup copies config.example.toml into the config dir and prints the path" "stdout: $out"
fi
printf 'voice = "Daniel"\n' >"$CASE_DIR/config/config.toml"
out="$(bash "$BLEAT" setup 2>/dev/null)"
if [ "$(cat "$CASE_DIR/config/config.toml")" = 'voice = "Daniel"' ] && [ "$out" = "$CASE_DIR/config/config.toml" ]; then
	pass "setup leaves an existing config.toml alone"
else
	fail "setup leaves an existing config.toml alone" "$(cat "$CASE_DIR/config/config.toml")" "stdout: $out"
fi

setup intro-prints
out="$(bash "$BLEAT" intro 2>"$CASE_DIR/stderr")"
if [ -n "$out" ] && [ "$out" = "$(cat "$ROOT/ON_STARTUP.md")" ]; then
	pass "intro prints ON_STARTUP.md"
else
	fail "intro prints ON_STARTUP.md" "$(cat "$CASE_DIR/stderr")" "$(printf '%s' "$out" | head -n 3)"
fi

setup intro-ansi
# In the popup the intro is styled with ANSI escapes: headings bold, inline
# code and indented blocks cyan, markdown markers gone. --ansi forces that
# rendering when stdout is not a terminal.
mkdir -p "$CASE_DIR/root"
printf '# Title\n\nText with `code` inline.\n\n    indented block\n\n## Sub\n' >"$CASE_DIR/root/ON_STARTUP.md"
B="$(printf '\033[1m')" C="$(printf '\033[36m')" R="$(printf '\033[0m')"
want="$(printf '%sTitle%s\n\nText with %scode%s inline.\n\n%s    indented block%s\n\n%sSub%s\n' "$B" "$R" "$C" "$R" "$C" "$R" "$B" "$R")"
out="$(HERDR_PLUGIN_ROOT="$CASE_DIR/root" bash "$BLEAT" intro --ansi 2>"$CASE_DIR/stderr")"
if [ "$out" = "$want" ]; then
	pass "intro --ansi styles headings and code"
else
	fail "intro --ansi styles headings and code" "$(printf '%s' "$out" | od -c | head -n 6)" "$(cat "$CASE_DIR/stderr")"
fi

# A fake herdr that records every call and answers `plugin pane open` with
# the exit status in $FAKE_POPUP_RC.
fake_herdr() {
	cat >"$CASE_DIR/herdr" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$CASE_DIR/herdr-calls"
case "\$1 \$2 \$3" in
"plugin pane open") exit "\${FAKE_POPUP_RC:-0}" ;;
esac
exit 0
FAKE
	chmod +x "$CASE_DIR/herdr"
	export HERDR_BIN_PATH="$CASE_DIR/herdr"
}
popup_opens() { grep -c '^plugin pane open --plugin bleatr --entrypoint intro$' "$CASE_DIR/herdr-calls" 2>/dev/null | tr -d ' '; }

setup startup-once
fake_herdr
bash "$BLEAT" startup 2>"$CASE_DIR/stderr"
bash "$BLEAT" startup 2>>"$CASE_DIR/stderr"
if [ "$(popup_opens)" = 1 ]; then
	pass "startup opens the intro popup once"
else
	fail "startup opens the intro popup once" "$(cat "$CASE_DIR/herdr-calls" 2>/dev/null)" "$(cat "$CASE_DIR/stderr")"
fi

setup startup-retries
fake_herdr
FAKE_POPUP_RC=1 bash "$BLEAT" startup 2>"$CASE_DIR/stderr"
FAKE_POPUP_RC=1 bash "$BLEAT" startup 2>>"$CASE_DIR/stderr"
if [ "$(popup_opens)" = 2 ] && grep -q '^notification show' "$CASE_DIR/herdr-calls"; then
	pass "startup tries the popup again next time when it cannot open, and toasts"
else
	fail "startup tries the popup again next time when it cannot open, and toasts" "$(cat "$CASE_DIR/herdr-calls" 2>/dev/null)" "$(cat "$CASE_DIR/stderr")"
fi

setup intro-action
fake_herdr
bash "$BLEAT" intro-popup 2>"$CASE_DIR/stderr"
bash "$BLEAT" startup 2>>"$CASE_DIR/stderr"
if [ "$(popup_opens)" = 1 ]; then
	pass "the intro action opens the popup and startup then stays quiet"
else
	fail "the intro action opens the popup and startup then stays quiet" "$(cat "$CASE_DIR/herdr-calls" 2>/dev/null)" "$(cat "$CASE_DIR/stderr")"
fi
unset HERDR_BIN_PATH

setup startup-cost
# An ignored event is the common case and runs on every status change, so it
# has to be cheap. Measured over ten runs to smooth out scheduler noise.
cat >"$CASE_DIR/config/config.toml" <<EOF
voice = "Daniel"
bell = "Crystal"
notify_on = ["done", "blocked"]
cooldown_seconds = 8
say_command = 'true'
EOF
start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
for i in 1 2 3 4 5 6 7 8 9 10; do run_bleat working >/dev/null; done
end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
per_run=$(((end_ms - start_ms) / 10))
# A shared CI runner is slower and noisier than a development machine, and a
# timing case that goes red for the noise says nothing about the code. The
# strict budget stays where the signal is.
budget=250
[ -n "${CI:-}" ] && budget=1000
if [ "$per_run" -lt "$budget" ]; then
	pass "an ignored event costs under $budget ms (${per_run} ms)"
else
	fail "an ignored event costs under $budget ms" "measured ${per_run} ms per run"
fi

setup lock-drops
# Speech still never overlaps, but the bleat that cannot have the floor drops
# instead of queueing behind it: a sentence that waited its turn describes a
# pane the user has already read. The second run starts once the first is
# inside `say`, so it always meets a held lock.
export BLEATR_SAY_COMMAND="printf 'start\n' >> \"$CASE_DIR/order\"; sleep 1; printf '%s\n' \"\$BLEATR_MESSAGE\" >> \"$CASE_DIR/said\"; printf 'end\n' >> \"$CASE_DIR/order\""
export BLEATR_COOLDOWN_SECONDS=0
run_bleat done >/dev/null &
first=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -s "$CASE_DIR/order" ] && break
	sleep 0.2
done
run_bleat blocked >/dev/null
wait "$first"
if [ "$(cat "$CASE_DIR/order" | tr '\n' ' ')" = "start end " ]; then
	pass "concurrent bleats do not overlap"
else
	fail "concurrent bleats do not overlap" "$(cat "$CASE_DIR/order" | tr '\n' ' ')"
fi
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ] && grep -q dropping "$CASE_DIR/stderr"; then
	pass "the second bleat is dropped and logged, and the first is unharmed"
else
	fail "the second bleat is dropped and logged, and the first is unharmed" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi

setup lock-abandoned
# A bleat killed outright never runs its EXIT trap, and the lock it leaves must
# not silence every notification after it. The pid inside names a process that
# is gone, so the next bleat takes the lock over -- and gives it back.
mkdir -p "$CASE_DIR/state/speaking.lock"
sh -c 'printf %s $$' >"$CASE_DIR/state/speaking.lock/pid"
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ] && [ ! -e "$CASE_DIR/state/speaking.lock" ]; then
	pass "a lock left behind by a dead bleat is taken over and released"
else
	fail "a lock left behind by a dead bleat is taken over and released" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi

setup lock-handover
# Once a lock has changed hands, the bleat that used to own it must not take
# the new owner's lock down with it on the way out -- a third bleat would then
# start talking over the second. A waits inside `say` holding the lock; its
# lock is aged so that B takes it over and holds it in turn; A is then let go,
# and C, arriving while B is still speaking, has to find B's lock and drop.
export BLEATR_NOTIFY_ON="done blocked idle"
BLEATR_SAY_COMMAND="printf '%s\n' \"\$BLEATR_MESSAGE\" >> \"$CASE_DIR/said\"; : > \"$CASE_DIR/a-up\"; while [ ! -e \"$CASE_DIR/a-go\" ]; do sleep 0.1; done" \
	run_bleat done >/dev/null &
a=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -e "$CASE_DIR/a-up" ] && break
	sleep 0.2
done
touch -t 202001010000 "$CASE_DIR/state/speaking.lock"
BLEATR_SAY_COMMAND="printf '%s\n' \"\$BLEATR_MESSAGE\" >> \"$CASE_DIR/said\"; : > \"$CASE_DIR/b-up\"; while [ ! -e \"$CASE_DIR/b-go\" ]; do sleep 0.1; done" \
	run_bleat blocked >/dev/null &
b=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -e "$CASE_DIR/b-up" ] && break
	sleep 0.2
done
: >"$CASE_DIR/a-go"
wait "$a"
run_bleat idle >/dev/null
: >"$CASE_DIR/b-go"
wait "$b"
if ! said | grep -q 'is idle'; then
	pass "a bleat whose lock was taken over leaves the new owner's alone"
else
	fail "a bleat whose lock was taken over leaves the new owner's alone" "$(said)"
fi

setup lock-stale
# The pid can outlive the bleat that wrote it -- wedged, or handed to something
# else after a reboot -- and a lock can exist for an instant before the pid is
# in it. Age is the backstop: nothing this plugin says takes minutes.
mkdir -p "$CASE_DIR/state/speaking.lock"
printf '%s' "$$" >"$CASE_DIR/state/speaking.lock/pid"
touch -t 202001010000 "$CASE_DIR/state/speaking.lock"
run_bleat done >/dev/null
if [ -e "$CASE_DIR/said" ]; then
	pass "a lock older than any sentence is taken over"
else
	fail "a lock older than any sentence is taken over" "$(cat "$CASE_DIR/stderr")"
fi

setup skip
# `skip` stops the sentence being spoken and nothing else. The fake say
# writes `end` two seconds in, and the case waits
# past that: a signal that reached the bleat but not the voice under it leaves
# the voice orphaned and still talking, which is the same as not skipping.
export BLEATR_SAY_COMMAND="printf 'start\n' >> \"$CASE_DIR/order\"; sleep 2; printf 'end\n' >> \"$CASE_DIR/order\""
export BLEATR_COOLDOWN_SECONDS=0
# The bleat is signalled, so it goes through a subshell that ends on `true`:
# a job this shell reaped as killed would print a Terminated notice among the
# results, which is noise here and looks like a failure.
(run_bleat done >/dev/null || true) 2>/dev/null &
first=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -s "$CASE_DIR/order" ] && break
	sleep 0.2
done
bash "$BLEAT" skip 2>"$CASE_DIR/skip-stderr"
wait "$first"
sleep 2.5
if [ "$(cat "$CASE_DIR/order" | tr '\n' ' ')" = "start " ]; then
	pass "skip stops the sentence being spoken"
else
	fail "skip stops the sentence being spoken" "$(cat "$CASE_DIR/order" 2>/dev/null | tr '\n' ' ')"
fi
# The skipped bleat still has to run its EXIT trap on the way out. A lock left
# behind would drop every notification after it for the next two minutes.
if [ ! -e "$CASE_DIR/state/speaking.lock" ]; then
	pass "the skipped bleat hands back the speech lock"
else
	fail "the skipped bleat hands back the speech lock" "$(find "$CASE_DIR/state")"
fi
BLEATR_SAY_COMMAND="printf '%s\n' \"\$BLEATR_MESSAGE\" >> \"$CASE_DIR/said\"" run_bleat blocked >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr is waiting for your approval or an answer." ]; then
	pass "a skip does not mute: the next notification speaks"
else
	fail "a skip does not mute: the next notification speaks" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi

setup skip-nothing-speaking
# Skipping when nothing is speaking is not an error: no output and a zero
# exit, including when a lock is lying around naming a bleat already gone,
# where the pid could since have been handed to something else entirely.
bash "$BLEAT" skip 2>"$CASE_DIR/skip-stderr"
rc=$?
mkdir -p "$CASE_DIR/state/speaking.lock"
sh -c 'printf %s $$' >"$CASE_DIR/state/speaking.lock/pid"
bash "$BLEAT" skip 2>>"$CASE_DIR/skip-stderr"
rc_stale=$?
if [ "$rc" = 0 ] && [ "$rc_stale" = 0 ] && [ ! -s "$CASE_DIR/skip-stderr" ]; then
	pass "skip with nothing speaking is a silent no-op"
else
	fail "skip with nothing speaking is a silent no-op" "rc $rc/$rc_stale" "$(cat "$CASE_DIR/skip-stderr")"
fi
rm -rf "$CASE_DIR/state/speaking.lock"
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ]; then
	pass "a skip that found nothing to stop does not mute either"
else
	fail "a skip that found nothing to stop does not mute either" "$(said)" "$(cat "$CASE_DIR/stderr")"
fi

setup skip-grandchild
# The pid in the lock is the bleat, and under say_command the voice is two
# levels below it: `sh -c` is the child and the speaker runs under that. A skip
# that killed only the direct child would orphan the speaker, which talks on --
# here, by writing `end` a couple of seconds after the skip. The trailing `:`
# keeps sh from exec'ing the script and collapsing the tree by a level.
cat >"$CASE_DIR/voice.sh" <<VOICE
#!/bin/sh
printf 'start\n' >> "$CASE_DIR/order"
sleep 2
printf 'end\n' >> "$CASE_DIR/order"
VOICE
chmod +x "$CASE_DIR/voice.sh"
export BLEATR_SAY_COMMAND="\"$CASE_DIR/voice.sh\"; :"
(run_bleat done >/dev/null || true) 2>/dev/null &
first=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -s "$CASE_DIR/order" ] && break
	sleep 0.2
done
bash "$BLEAT" skip 2>"$CASE_DIR/skip-stderr"
wait "$first"
sleep 2.5
if [ "$(cat "$CASE_DIR/order" | tr '\n' ' ')" = "start " ]; then
	pass "skip silences a say_command speaker running under sh -c"
else
	fail "skip silences a say_command speaker running under sh -c" "$(cat "$CASE_DIR/order" 2>/dev/null | tr '\n' ' ')"
fi

setup rate
# `rate` is words per minute and reaches `say` as -r. The other cases replace
# `say` with say_command; this one needs the real code path, so a fake `say`
# goes on PATH -- which is also the only `say` a Linux runner has.
unset BLEATR_SAY_COMMAND
export BLEATR_COOLDOWN_SECONDS=0
mkdir -p "$CASE_DIR/bin"
cat >"$CASE_DIR/bin/say" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$CASE_DIR/say-args"
FAKE
chmod +x "$CASE_DIR/bin/say"
sentence="Claude in herdr-bleatr finished and is waiting for you."
PATH="$CASE_DIR/bin:$PATH" run_bleat done >/dev/null
if [ "$(cat "$CASE_DIR/say-args" 2>/dev/null)" = "-- $sentence" ]; then
	pass "an unset rate passes no rate flag at all"
else
	fail "an unset rate passes no rate flag at all" "$(cat "$CASE_DIR/say-args" 2>/dev/null)" "$(cat "$CASE_DIR/stderr")"
fi
rm -f "$CASE_DIR/say-args"
BLEATR_RATE=220 PATH="$CASE_DIR/bin:$PATH" run_bleat done >/dev/null
if [ "$(cat "$CASE_DIR/say-args" 2>/dev/null)" = "-r 220 -- $sentence" ]; then
	pass "rate reaches say as -r words per minute"
else
	fail "rate reaches say as -r words per minute" "$(cat "$CASE_DIR/say-args" 2>/dev/null)"
fi
rm -f "$CASE_DIR/say-args"
BLEATR_VOICE="Bad News" BLEATR_RATE=220 PATH="$CASE_DIR/bin:$PATH" run_bleat done >/dev/null
if [ "$(cat "$CASE_DIR/say-args" 2>/dev/null)" = "-v Bad News -r 220 -- $sentence" ]; then
	pass "a voice with a space in it survives alongside the rate"
else
	fail "a voice with a space in it survives alongside the rate" "$(cat "$CASE_DIR/say-args" 2>/dev/null)"
fi
rm -f "$CASE_DIR/say-args"
# A rate `say` would refuse costs the whole sentence, so a value that is not a
# positive number is dropped instead of passed on.
printf 'rate = "fast"\n' >"$CASE_DIR/config/config.toml"
out="$(bash "$BLEAT" config 2>/dev/null)"
PATH="$CASE_DIR/bin:$PATH" run_bleat done >/dev/null
if printf '%s\n' "$out" | grep -q '^rate=$' && [ "$(cat "$CASE_DIR/say-args" 2>/dev/null)" = "-- $sentence" ]; then
	pass "a non-numeric rate is dropped rather than passed on"
else
	fail "a non-numeric rate is dropped rather than passed on" "$(cat "$CASE_DIR/say-args" 2>/dev/null)" "$out"
fi

setup rate-say-command
# A custom say_command owns its own rate, the way it owns its own voice: the
# `say` path is not taken at all, so there is nowhere for a flag to be added.
mkdir -p "$CASE_DIR/bin"
cat >"$CASE_DIR/bin/say" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$CASE_DIR/say-args"
FAKE
chmod +x "$CASE_DIR/bin/say"
export BLEATR_RATE=220
PATH="$CASE_DIR/bin:$PATH" run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ] && [ ! -e "$CASE_DIR/say-args" ]; then
	pass "rate is ignored when say_command is set"
else
	fail "rate is ignored when say_command is set" "$(said)" "$(cat "$CASE_DIR/say-args" 2>/dev/null)"
fi

# --- live case ---------------------------------------------------------------

if [ "${BLEATR_LIVE:-}" = 1 ] && [ "${HERDR_ENV:-}" = 1 ]; then
	HERDR="${HERDR_BIN_PATH:-herdr}"
	if "$HERDR" plugin list --plugin bleatr >/dev/null 2>&1; then
		live_config="$("$HERDR" plugin config-dir bleatr)/config.toml"
		saved=""
		if [ -f "$live_config" ]; then
			saved="$WORK/config.toml.saved"
			cp "$live_config" "$saved"
		fi
		record="$WORK/live-said"
		cat >"$live_config" <<EOF
summary_model = "none"
cooldown_seconds = 0
say_command = 'printf "%s\n" "\$BLEATR_MESSAGE" >> "$record"'
EOF
		# The scratch pane goes in its own unfocused tab: a pane in the tab
		# being looked at is never spoken.
		tab="$("$HERDR" tab create --cwd "$PWD" --label bleatr-test --no-focus | jq -r '.result.tab.tab_id')"
		pane="$("$HERDR" pane list | jq -r --arg t "$tab" '.result.panes[] | select(.tab_id == $t) | .pane_id' | head -n 1)"
		"$HERDR" pane report-agent "$pane" --source custom:bleatr-test --agent bleatbot --state working >/dev/null
		sleep 1
		"$HERDR" pane report-agent "$pane" --source custom:bleatr-test --agent bleatbot --state idle --seq 2 >/dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			[ -s "$record" ] && break
			sleep 1
		done
		"$HERDR" tab close "$tab" >/dev/null
		if [ -n "$saved" ]; then cp "$saved" "$live_config"; else rm -f "$live_config"; fi
		if grep -q "Bleatbot in .* finished and is waiting for you." "$record" 2>/dev/null; then
			pass "live: a real status change reaches say through the Herdr event hook"
		else
			fail "live: a real status change reaches say through the Herdr event hook" "$(cat "$record" 2>/dev/null)" \
				"$("$HERDR" plugin log list --plugin bleatr --limit 2 | jq -c '.result.logs[] | {status, stdout, stderr}')"
		fi
	else
		printf 'skip live: plugin bleatr is not linked\n'
	fi
else
	printf 'skip live: set BLEATR_LIVE=1 inside a Herdr session with the plugin linked\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
