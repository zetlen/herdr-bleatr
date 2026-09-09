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
For a voice that sounds like a person, on any platform, see Pocket TTS below.

## A neural voice with Pocket TTS

`say_command` replaces the speech tool with any shell command; the sentence
is in `$BLEATR_MESSAGE`. That is how Bleatr speaks through Pocket TTS
(github.com/kyutai-labs/pocket-tts), a 100-million-parameter voice model that
runs on two CPU cores. Its server keeps the model loaded, so a sentence comes
back in under a second. Install it and run the server:

    uv tool install pocket-tts --index https://download.pytorch.org/whl/cpu
    pocket-tts serve --host 127.0.0.1 --port 8000

The index flag keeps the CPU build of PyTorch, which is a fraction of the
size of the default one. The first run downloads the model weights.

The server answers `POST /tts` with a `text` form field by streaming a WAV.
Pipe that into a player. `ffplay` comes with ffmpeg and `aplay` with
alsa-utils:

    say_command = 'curl -s --data-urlencode "text=$BLEATR_MESSAGE" -d voice_url=alba http://127.0.0.1:8000/tts | ffplay -nodisp -autoexit -loglevel quiet -'

    say_command = 'curl -s --data-urlencode "text=$BLEATR_MESSAGE" -d voice_url=alba http://127.0.0.1:8000/tts | aplay -q -'

`voice_url` names a built-in voice: alba, marius, jean, anna, charles, paul,
george, mary, and others listed in the Pocket TTS README. It also takes a URL
or an `hf://` path to a WAV file of your own. Leave it out and the server
uses its `--default-voice`.

### Keep the server running on Linux

A systemd user service starts it at login. Put this in
`~/.config/systemd/user/pocket-tts.service`:

    [Service]
    ExecStart=%h/.local/bin/pocket-tts serve --host 127.0.0.1 --port 8000

    [Install]
    WantedBy=default.target

    systemctl --user enable --now pocket-tts

To start the server only when a sentence arrives and stop it when idle, let
systemd hold the port. Pocket TTS binds its own port, so a proxy sits in
between: systemd listens on 8000, the proxy forwards to the server on 8001
and exits after ten idle minutes, and the server stops with it. Three files
in `~/.config/systemd/user/`:

    # pocket-tts.socket
    [Socket]
    ListenStream=127.0.0.1:8000

    [Install]
    WantedBy=sockets.target

    # pocket-tts.service   (the proxy; its name matches the socket)
    [Unit]
    Requires=pocket-tts-server.service
    After=pocket-tts-server.service

    [Service]
    ExecStart=/usr/lib/systemd/systemd-socket-proxyd --exit-idle-time=10min 127.0.0.1:8001

    # pocket-tts-server.service
    [Unit]
    StopWhenUnneeded=yes

    [Service]
    ExecStart=%h/.local/bin/pocket-tts serve --host 127.0.0.1 --port 8001

    systemctl --user enable --now pocket-tts.socket

The model takes a few seconds to load, and the proxy passes the first
connection through before the server is listening, so that request fails.
Add retries to curl in `say_command`:

    curl -s --retry 5 --retry-all-errors --retry-delay 2 ...

### Keep the server running on macOS

A launch agent starts it at login and restarts it if it exits. Put this in
`~/Library/LaunchAgents/dev.kyutai.pocket-tts.plist`:

    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>dev.kyutai.pocket-tts</string>
      <key>ProgramArguments</key><array>
        <string>/Users/you/.local/bin/pocket-tts</string>
        <string>serve</string><string>--host</string><string>127.0.0.1</string>
        <string>--port</string><string>8000</string>
      </array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
    </dict></plist>

    launchctl bootstrap gui/$UID ~/Library/LaunchAgents/dev.kyutai.pocket-tts.plist

`afplay` does not read a pipe, so use `ffplay` from `brew install ffmpeg`,
or save the WAV to a file first and play that.

### Play on another machine

Plugin commands run on the machine that runs the Herdr server. When that is
a VM or a remote box with no speakers, run Pocket TTS wherever it fits and
send the audio to the machine you are sitting at over SSH:

    say_command = 'curl -s --data-urlencode "text=$BLEATR_MESSAGE" -d voice_url=jean http://tts-host:8000/tts | ssh desk "ffplay -nodisp -autoexit -loglevel quiet -"'

The sentence is stripped of shell metacharacters before it reaches
`say_command`, so it is safe inside the quoted remote command.

## A hosted voice with ElevenLabs

The same `say_command` route reaches a hosted voice. ElevenLabs bills per
character, and a notification is about one hundred and fifty characters.
Keep the API key and the request in Bleatr's config directory, which plugin
commands see as `$HERDR_PLUGIN_CONFIG_DIR`:

    cd "$(herdr plugin config-dir bleatr)"
    printf '%s' 'sk_...' > elevenlabs-key
    chmod 600 elevenlabs-key

Pick a voice id from your library:

    curl -s -H "xi-api-key: $(cat elevenlabs-key)" https://api.elevenlabs.io/v1/voices | jq -r '.voices[] | "\(.voice_id)  \(.name)"'

Save this as `elevenlabs-say` in the same directory, with your voice id in
place of `VOICE_ID`. It builds the request with `jq` and pipes the MP3 into
a player:

    #!/bin/sh
    dir="$HERDR_PLUGIN_CONFIG_DIR"
    jq -n --arg t "$BLEATR_MESSAGE" '{text: $t, model_id: "eleven_flash_v2_5"}' |
    curl -s -H "xi-api-key: $(cat "$dir/elevenlabs-key")" \
        -H 'content-type: application/json' -d @- \
        'https://api.elevenlabs.io/v1/text-to-speech/VOICE_ID?output_format=mp3_22050_32' |
    ffplay -nodisp -autoexit -loglevel quiet -

Then point `say_command` at it:

    say_command = 'sh "$HERDR_PLUGIN_CONFIG_DIR/elevenlabs-say"'

`eleven_flash_v2_5` is the low-latency model. `eleven_multilingual_v2`
sounds better and takes longer. An `output_format` of `pcm_22050` returns
raw 16-bit audio that `aplay -q -f S16_LE -r 22050 -` plays without a
decoder.

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
