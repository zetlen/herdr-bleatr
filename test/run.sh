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

event() { # status [agent]
	jq -cn --arg s "$1" --arg a "${2:-claude}" \
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
if grep -q '^Event: done' "$CASE_DIR/prompt" && grep -q '^Agent: claude' "$CASE_DIR/prompt" &&
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

setup summarizer-fails
export BLEATR_SUMMARIZE_COMMAND="echo boom >&2; exit 1"
run_bleat done >/dev/null
if [ "$(said)" = "Claude in herdr-bleatr finished and is waiting for you." ] && grep -q boom "$CASE_DIR/state/summarize.err"; then
	pass "a failing summarizer falls back to the template and logs stderr"
else
	fail "a failing summarizer falls back to the template and logs stderr" "$(said)" "$(cat "$CASE_DIR/state/summarize.err" 2>/dev/null)"
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

setup cooldown
run_bleat done >/dev/null
run_bleat done >/dev/null
run_bleat blocked >/dev/null
if [ "$(said | wc -l | tr -d ' ')" = 2 ]; then
	pass "a repeat within the cooldown is skipped, a different status is not"
else
	fail "a repeat within the cooldown is skipped, a different status is not" "$(said)"
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
if [ "$per_run" -lt 250 ]; then
	pass "an ignored event costs under 250 ms (${per_run} ms)"
else
	fail "an ignored event costs under 250 ms" "measured ${per_run} ms per run"
fi

setup lock-serializes
export BLEATR_SAY_COMMAND="printf 'start\n' >> \"$CASE_DIR/order\"; sleep 1; printf 'end\n' >> \"$CASE_DIR/order\""
export BLEATR_COOLDOWN_SECONDS=0
run_bleat done >/dev/null &
run_bleat blocked >/dev/null &
wait
if [ "$(cat "$CASE_DIR/order" | tr '\n' ' ')" = "start end start end " ]; then
	pass "concurrent bleats do not overlap"
else
	fail "concurrent bleats do not overlap" "$(cat "$CASE_DIR/order" | tr '\n' ' ')"
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
