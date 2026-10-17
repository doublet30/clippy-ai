pragma Singleton
import QtQuick
import Quickshell

// Text-to-speech through external engines (no Qt TextToSpeech dependency).
//
//   engine "auto" (default): Piper neural voice if a working Piper + voice model is found, else espeak-ng.
//   engine "piper" | "espeak" | "custom" (tts.command with {text} placeholder).
//
// config.json:
//   "tts": { "enabled": true, "engine": "auto",
//            "piper": { "binary": "/path/piper", "model": "/path/en_US-ryan-high.onnx", "speed": 1.0 },
//            "voice": "en-us", "rate": 170, "pitch": 60,            // espeak-ng
//            "command": ["my-tts", "{text}"] }                      // custom
//
// Piper voices are searched in ~/.local/share/clippy-ai/voices, ~/.local/share/ttos/assistant/piper and
// /usr/share/piper-voices; male voices are preferred (ryan, joe, alan, ...). See docs/VOICES.md.
Singleton {
    id: root

    property bool speaking: false
    property var _proc: null
    readonly property bool enabled: !Config.muted && Config.tts.enabled !== false

    // detected Piper installation
    property string piperBin: ""
    property string piperModel: ""
    property int piperRate: 22050
    readonly property string engine: {
        var e = Config.tts.engine || (Config.tts.command ? "custom" : "auto")
        if (e === "auto") return piperBin && piperModel ? "piper" : "espeak"
        if (e === "piper" && !(piperBin && piperModel)) return "espeak"
        return e
    }
    readonly property string voiceName: engine === "piper" ? piperModel.split("/").pop().replace(/\.onnx$/, "") : (engine === "espeak" ? "espeak-ng" : "custom")

    // Estimated ms per word so the on-screen "paste" tracks the voice.
    readonly property real msPerWord: engine === "piper" ? 60000 / (155 / Math.max(0.5, Config.tts.piper && Config.tts.piper.speed ? Config.tts.piper.speed : 1))
                                                        : 60000 / (Config.tts.rate || 170)

    function init() {
        var pc = Config.tts.piper || {}
        // Detection benchmarks voices the first time (can take ~10 s); espeak-ng is used until it finishes.
        Sys.run(["bash", Quickshell.shellPath("qml/scripts/piper-detect.sh"), pc.binary || "", pc.model || ""], (c, o) => {
            var l = o.split("\n")
            piperBin = l[0] || ""; piperModel = l[1] || ""; piperRate = parseInt(l[2]) || 22050
            console.log("clippy-ai: speech engine=" + engine + (engine === "piper" ? " voice=" + voiceName + " rtf=" + l[3] : (piperBin ? " (no Piper voice fast enough; see docs/VOICES.md)" : "")))
        })
    }

    function _clean(t) {
        return t.replace(/```[\s\S]*?```/g, " code block. ").replace(/[*_`#>]/g, "").replace(/https?:\/\/\S+/g, "link")
                .replace(/~\//g, "home slash ").replace(/\s+/g, " ").trim()
    }

    // Piper pipeline, run in its own process group so stop() can kill synthesis AND playback.
    readonly property string piperScript:
        'trap "kill 0" TERM INT\n' +
        '( printf "%s" "$1" | LD_LIBRARY_PATH="$(dirname "$2")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$2" --model "$3" --length_scale "$4" --output-raw 2>/dev/null | ' +
        '{ if command -v paplay >/dev/null 2>&1; then paplay --raw --rate="$5" --format=s16le --channels=1; ' +
        'elif command -v pw-cat >/dev/null 2>&1; then pw-cat --playback --raw --rate "$5" --channels 1 --format s16 -; ' +
        'else aplay -q -t raw -f S16_LE -r "$5" -c 1 -; fi; } ) &\n' +
        'wait $!'

    function speak(text, done) {
        stop()
        if (!enabled) { if (done) Qt.callLater(done); return false }
        var t = _clean(text)
        var cmd
        if (engine === "piper") {
            var speed = Config.tts.piper && Config.tts.piper.speed ? Config.tts.piper.speed : 1
            cmd = ["setsid", "bash", "-c", piperScript, "_", t, piperBin, piperModel, "" + (1 / speed), "" + piperRate]
        } else if (engine === "custom" && Config.tts.command) {
            cmd = Config.tts.command.map(x => x === "{text}" ? t : x)
        } else {
            cmd = ["espeak-ng", "-v", Config.tts.voice || "en-us", "-s", "" + (Config.tts.rate || 170), "-p", "" + (Config.tts.pitch || 60), "--", t]
        }
        speaking = true
        var me = Sys.run(cmd, () => { if (_proc === me) { speaking = false; _proc = null; if (done) done() } })
        _proc = me
        return true
    }
    function stop() {
        if (_proc) { var p = _proc; _proc = null; speaking = false; try { p.running = false } catch (e) {} }
    }
}
