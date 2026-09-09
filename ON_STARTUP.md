Bleatr speaks agent notifications aloud. When an agent in a tab you are not
looking at finishes, or stops to ask you something, it says one sentence:

    "Claude in herdr-bleatr finished the plugin tests and wants you to
    review the README."

Bleatr works without a config file. The three steps below tune it.

## 1. Turn off Herdr's own sound

Bleatr speaks at the moments Herdr plays its notification sound, so with
both on you hear a chime and then a sentence. In Herdr's config.toml:

    [ui.sound]
    enabled = false

Leave `[ui.toast]` as it is. Bleatr's `bell = "terminal"` setting delivers
its bell through a Herdr toast, which is how a bell reaches you over SSH.

## 2. Choose who writes the sentence

Each notification makes one small model call through a CLI you already
have. Set `summary_model` in Bleatr's config file to one of:

    "claude"   the claude CLI (Claude Code), logged in. About three seconds
               and half a cent per notification. This is the default.
    "codex"    the codex CLI, logged in.
    "none"     no model. A plain template sentence, such as
               "Claude in herdr-bleatr finished and is waiting for you."

Any other CLI that reads a prompt on stdin works through
`summarize_command`. The config file has examples.

## 3. On Linux, install a speech command

Bleatr speaks with macOS `say`. On Linux it uses the first of `spd-say`,
`espeak-ng`, or `espeak` that is installed. Package repositories carry
`espeak-ng` under that name; `spd-say` comes with `speech-dispatcher`. A
bell sound file plays through `paplay`, `pw-play`, `ffplay`, or `aplay`.

## Set it up

Create the config file, then edit the keys above in it. Every key is
documented in the file:

    herdr plugin action invoke bleatr.setup

Hear a test sentence from any agent pane:

    herdr plugin action invoke bleatr.test

Mute and unmute without disabling the plugin:

    herdr plugin action invoke bleatr.toggle

See this page again:

    herdr plugin action invoke bleatr.intro
