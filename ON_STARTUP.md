# Herdr Bleatr: orientation

Bleatr is a Herdr plugin that speaks agent notifications aloud. Herdr runs
`bin/bleat` on every `pane.agent_status_changed` event. When the new status is
one the user wants to hear, the script asks a small model for one sentence
about the agent's last message, optionally plays a bell, and runs `say`.

## Files

- `herdr-plugin.toml` declares the event hook and three actions: `test`,
  `setup`, and `toggle`.
- `bin/bleat` is the whole plugin. It is one bash script written for bash 3.2.
- `config.example.toml` documents every config key. The `setup` action copies
  it into the plugin config directory.
- `test/run.sh` runs the tests with fake `say`, bell, and summarizer commands.
  The last case needs a live Herdr session.
- `README.md` is the user-facing guide.

## How the hook decides to speak

The `bleat` function in `bin/bleat` runs these checks in order and returns on
the first one that fails:

1. The event carries an agent status.
2. The status is listed in `notify_on`. The default is `done` and `blocked`.
3. Speech is not muted.
4. The pane is not in the focused tab. The event context names the pane's
   tab, and `herdr api snapshot` names the focused tab. A failed lookup
   counts as not focused. The `test` subcommand skips this check because
   the current pane is always in the focused tab.
5. The same pane and status were not spoken inside `cooldown_seconds`.

Only then does it call Herdr for the pane details and transcript, run the
summarizer, take the speech lock, play the bell, and speak.

Every setting can be overridden with an environment variable named
`BLEATR_<KEY>`. The tests use these, plus `BLEATR_SKIP_HERDR=1` so the script
never calls Herdr.

## Open issue and suggested approach

### Install wizard (issue #2)

The issue asks for an installation flow that tells the user to turn off
Herdr's regular notifications, lets them choose a summarizer preset, and
suggests speech options on Linux.

What Herdr offers a plugin:

- Build commands run during `herdr plugin install` without the socket or any
  plugin context. They cannot ask questions.
- Startup hooks run once per enabled plugin after Herdr restores the session.
  The docs describe them as one-shot initialization commands that run and
  exit. Nothing in the docs gives them a terminal.
- A `[[panes]]` entry runs a command in a terminal pane and can take keyboard
  input. `placement = "popup"` makes it a session-modal popup that closes
  when the command exits. The Herdr 0.9.0 docs describe it. The manifest
  declares `min_herdr_version = "0.7.0"`. Which version added popup placement
  is not verified.

Suggested shape:

- Add a popup pane that runs an interactive bash wizard. Open it from the
  `setup` action after the config file is copied.
- Notifications: print the Herdr config snippet for the user to paste. Do not
  edit Herdr's own `config.toml`. Recommend disabling `[ui.sound]` only. The
  `bell = "terminal"` mode delivers the bell through `herdr notification
  show`, so disabling `[ui.toast]` silences that bell.
- Preset: check which of `claude` and `codex` are on `PATH`, offer those plus
  `none`, and write the answer to `summary_model` in the new config file.
- Linux: check for `spd-say`, `espeak-ng`, `espeak`, and an audio player, and
  print install hints for whatever is missing. The `speak` function already
  tries those speech commands in that order, and `play_bell` tries `afplay`,
  `paplay`, `pw-play`, `ffplay`, then `aplay`.
- Optional: a startup hook that shows a Herdr toast pointing at `setup` when
  no config file exists, and records in the state directory that it has done
  so.
