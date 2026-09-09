# Herdr Bleatr

A [Herdr](https://herdr.dev) plugin that speaks agent notifications aloud. When
an agent finishes in a background tab, or stops to ask you something, Bleatr
reads the pane's recent output, asks a small model for one spoken sentence, and
says it with the macOS `say` command:

> "Claude in herdr-bleatr finished the notifications plugin and is waiting for review."

> "Codex in api needs approval to run the database migration."

## How it works

Herdr has no "notification" event on its socket API. Its toasts and sounds come
from agent lifecycle changes, so Bleatr hooks the same source: the
`pane.agent_status_changed` event. For each status in `notify_on` (by default
`done` and `blocked`) it:

1. Reads the pane, workspace, tab, and agent from the event and invocation
   context Herdr injects into the hook.
2. Calls `herdr agent get` for the agent's name and session title, and
   `herdr agent read` for the last lines of terminal output.
3. Writes a prompt to a temp file and runs the summarizer for that
   `summary_model` preset. If the model is unavailable or slow, a template
   sentence is spoken instead.
4. Plays the `bell` sound, if one is configured, then runs `say`. Speech is
   serialized with a lock so two agents finishing together do not talk over
   each other.

`done` is reported only for tabs you have not looked at since the agent
finished, so a focused, visible agent finishing its turn stays quiet. `blocked`
is spoken regardless.

## Requirements

- Herdr 0.7.0 or newer.
- `bash` and `jq`.
- macOS `say`. On Linux, `spd-say`, `espeak-ng`, or `espeak` is used when
  present, and `say_command` covers anything else.
- For the summarizer: the `claude` CLI (Claude Code) or `codex` CLI, logged in.
  Each notification costs one small model call; the `claude` preset measured
  about 3 seconds and half a cent with thinking disabled. Set
  `summary_model = "none"` to speak the template sentence for free.

## Install

From GitHub:

```sh
herdr plugin install zetlen/herdr-bleatr
```

Or link a local checkout while developing:

```sh
git clone https://github.com/zetlen/herdr-bleatr
herdr plugin link herdr-bleatr
```

Then try it from any agent pane:

```sh
herdr plugin action invoke bleatr.test
```

## Configure

```sh
cp config.example.toml "$(herdr plugin config-dir bleatr)/config.toml"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `voice` | system voice | Voice passed to `say -v`. List them with `say -v '?'`. |
| `bell` | `false` | Sound before speaking: a macOS system sound name like `"Glass"`, or a file path. |
| `summary_model` | `"claude"` | `claude` (Claude Code, haiku, thinking off), `codex` (Codex CLI, gpt-5.1-codex-mini), or `none`. |
| `model_id` | preset's model | Override the preset's model id. |
| `notify_on` | `["done", "blocked"]` | Agent statuses that are spoken. |
| `cooldown_seconds` | `8` | Ignore a repeat of the same pane and status inside this window. |
| `max_words` | `25` | Word budget for the sentence. |
| `transcript_lines` | `60` | Terminal lines sent to the model. |
| `summary_timeout_seconds` | `25` | Give up on the model after this long. |
| `say_command` | unset | Advanced: replaces `say`. Runs under `sh -c` with the sentence in `$BLEATR_MESSAGE`. `voice` is then ignored. |
| `summarize_command` | unset | Advanced: replaces the preset. Runs under `sh -c` with the prompt path in `$BLEATR_PROMPT_FILE` and on stdin; prints the sentence. `summary_model` is then ignored. |

Every key can be overridden with an environment variable named
`BLEATR_<KEY>` in upper case, which is handy for one-off tests:

```sh
BLEATR_VOICE=Daniel BLEATR_SUMMARY_MODEL=none bash bin/bleat test
```

`bash bin/bleat config` prints the config path and the effective settings.

## Mute

The `toggle` action mutes and unmutes speech without disabling the plugin, and
confirms with a Herdr toast. Bind it in Herdr's `config.toml`:

```toml
[[keys.command]]
key = "prefix+m"
type = "plugin_action"
command = "bleatr.toggle"
description = "Bleatr: mute / unmute"
```

Or from a shell: `herdr plugin action invoke bleatr.toggle`.

## Troubleshooting

- `herdr plugin log list --plugin bleatr` shows each hook run, the sentence it
  spoke on stdout, and any errors on stderr.
- Summarizer stderr is appended to `summarize.err` in the plugin state
  directory (`~/.local/state/herdr/plugins/bleatr` by default).
- `BLEATR_DEBUG=1` logs the decision path and keeps the prompt file in
  `$TMPDIR` for inspection.

## Development

`test/run.sh` exercises the hook with fake `say`, bell, and summarizer commands
so no audio plays and no model is billed. Most cases run without Herdr; the
last one needs a live Herdr session and drives a scratch pane in the current
workspace through the real event path.
