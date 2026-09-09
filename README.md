# Herdr Bleatr

A [Herdr](https://herdr.dev) plugin that speaks agent notifications aloud. When
an agent finishes in a background tab, or stops to ask you something, Bleatr
says one sentence with the macOS `say` command:

> "Claude in herdr-bleatr finished the notifications plugin and is waiting for review."

> "Codex in api needs approval to run the database migration."

## Requirements

- Herdr 0.7.0 or newer.
- `bash` and `jq`.
- macOS `say`. On Linux, `spd-say`, `espeak-ng`, or `espeak` is used when
  present.
- The `claude` CLI (Claude Code) or `codex` CLI, logged in. Each notification
  makes one small model call. Set `summary_model = "none"` to skip the model
  and speak a plain template sentence.

## Install

From GitHub:

```sh
herdr plugin install zetlen/herdr-bleatr
```

Or link a local checkout:

```sh
git clone https://github.com/zetlen/herdr-bleatr
herdr plugin link herdr-bleatr
```

Then speak a test notification from any agent pane:

```sh
herdr plugin action invoke bleatr.test
```

## Configure

Copy the example config into place and edit it:

```sh
cp config.example.toml "$(herdr plugin config-dir bleatr)/config.toml"
```

Every key is documented in `config.example.toml`. Any key can also be set
with an environment variable named `BLEATR_<KEY>` in upper case:

```sh
BLEATR_VOICE=Daniel BLEATR_SUMMARY_MODEL=none bash bin/bleat test
```

Print the config path and the effective settings:

```sh
bash bin/bleat config
```

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

Or from a shell:

```sh
herdr plugin action invoke bleatr.toggle
```

## Troubleshooting

Show each hook run, the sentence it spoke, and any errors:

```sh
herdr plugin log list --plugin bleatr
```

Summarizer stderr is appended to `summarize.err` in the plugin state
directory, `~/.local/state/herdr/plugins/bleatr` by default.

Set `BLEATR_DEBUG=1` to log the decision path and keep the prompt file in
`$TMPDIR` for inspection.

## Development

Run the tests:

```sh
test/run.sh
```

They use fake `say`, bell, and summarizer commands, so no audio plays and no
model is billed. The last case needs a live Herdr session and drives a scratch
pane in the current workspace.
