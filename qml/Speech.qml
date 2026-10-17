pragma Singleton
import QtQuick
import Quickshell

// Text-to-speech via an external engine (no Qt TextToSpeech dependency).
// config.json:  "tts": { "command": ["piper-wrapper", "{text}"], "rate": 170, "pitch": 60, "voice": "en-us", "enabled": true }
// "{text}" is replaced by the sentence; default engine is espeak-ng.
Singleton {
    id: root
    property bool speaking: false
    property var _proc: null
    readonly property bool enabled: !Config.muted && Config.tts.enabled !== false

    // Estimated ms per word so the on-screen "paste" tracks the voice.
    readonly property real msPerWord: 60000 / (Config.tts.rate || 170)

    function _clean(t) {
        return t.replace(/```[\s\S]*?```/g, " code block. ").replace(/[*_`#>]/g, "").replace(/https?:\/\/\S+/g, "link").replace(/\s+/g, " ").trim()
    }

    function speak(text, done) {
        stop()
        if (!enabled) { if (done) Qt.callLater(done); return false }
        var t = _clean(text)
        var cmd = Config.tts.command
        cmd = cmd ? cmd.map(x => x === "{text}" ? t : x)
                  : ["espeak-ng", "-v", Config.tts.voice || "en-us", "-s", "" + (Config.tts.rate || 170), "-p", "" + (Config.tts.pitch || 60), "--", t]
        speaking = true
        var me = Sys.run(cmd, () => { if (_proc === me) { speaking = false; _proc = null; if (done) done() } })
        _proc = me
        return true
    }
    function stop() {
        if (_proc) { var p = _proc; _proc = null; speaking = false; try { p.running = false } catch (e) {} }
    }
}
