pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Thin process layer. Everything that touches the OS (terminal tool, TTS,
// desktop control bridges) goes through here so it can be sandboxed / audited.
Singleton {
    id: root

    function env(name) { return Quickshell.env(name) || "" }
    function home() { return env("HOME") }

    // run(["cmd", "arg"], (exitCode, stdout) => {...}) -> Process (set .running=false to kill)
    function run(cmd, cb) {
        var p = proc.createObject(root, { command: cmd })
        p.cb = cb
        p.running = true
        return p
    }

    Component {
        id: proc
        Process {
            id: p
            property var cb
            property int code: -1
            property bool exited: false
            property bool flushed: false
            function check() {
                if (exited && flushed) {
                    if (cb) cb(code, out.text)
                    destroy(50)
                }
            }
            stdout: StdioCollector { id: out; onStreamFinished: { p.flushed = true; p.check() } }
            onExited: (c, s) => { p.code = c; p.exited = true; p.check() }
        }
    }
}
