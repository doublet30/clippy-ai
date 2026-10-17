pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Client for the RevolutionWM agent API (docs/COMPOSITOR_API.md): newline-delimited JSON-RPC 2.0 over
// $XDG_RUNTIME_DIR/revolution/agent.sock. When the socket is absent everything here is inert.
//
// On connect: hello -> tools.list -> every advertised tool is registered in Tools, so new window/UI/app
// capabilities appear in the agent without any change to this repo. Server confirm requests
// ({confirm, token}) are routed to the Allow/Deny bubble through ctx.confirm.
Singleton {
    id: root

    readonly property string socketPath: Sys.env("CLIPPY_AGENT_SOCK") || (Sys.env("XDG_RUNTIME_DIR") + "/revolution/agent.sock")
    property bool available: false
    property string backend: ""             // "wayland" | "x11"
    property var capabilities: []
    property var toolNames: []              // tools registered from the server's catalogue

    signal event(string type, var data)     // window.added, window.changed, ui.dialog_opened, ...

    property int _nextId: 1
    property var _pending: ({})

    function start() { probe.restart(); _probe() }

    // call(method, params, cb(error, result))
    function call(method, params, cb) {
        if (!sock.connected) { if (cb) cb("not connected", null); return }
        var id = _nextId++
        if (cb) _pending[id] = cb
        sock.write(JSON.stringify({ jsonrpc: "2.0", id: id, method: method, params: params || {} }) + "\n")
        sock.flush()
    }

    function _probe() {
        if (sock.connected) return
        Sys.run(["test", "-S", socketPath], c => { if (c === 0 && !sock.connected) sock.connected = true })
    }

    function _handshake() {
        call("hello", { client: "clippy-ai", protocol: 1 }, (err, r) => {
            if (err) return console.warn("clippy-ai: agent API hello failed: " + err)
            backend = r.backend || ""; capabilities = r.capabilities || []; available = true
            console.log("clippy-ai: connected to " + (r.server || "window manager") + " (" + backend + ") caps=" + capabilities.join(","))
            call("tools.list", {}, (e2, list) => { if (!e2) _registerTools(list || []) })
        })
    }

    // Each catalogue entry: {name, description, parameters, dangerous?, anim?}
    function _registerTools(list) {
        _unregisterTools()
        var names = []
        list.forEach(t => {
            names.push(t.name)
            Tools.register({
                name: t.name, description: t.description, parameters: t.parameters || { type: "object", properties: {} },
                anim: t.anim || "GetTechy",
                run: (args, done, ctx) => {
                    var invoke = confirmToken => call("tools.call", { name: t.name, args: args, confirm_token: confirmToken }, (err, res) => {
                        if (err) return done("Error: " + (err.message || err))
                        if (res && typeof res === "object" && res.confirm)       // server wants the user's OK for this exact call
                            return ctx.confirm(res.confirm, ok => ok ? invoke(res.token) : done("The user declined."))
                        done(typeof res === "string" ? res : JSON.stringify(res))
                    })
                    invoke(undefined)
                }
            })
        })
        toolNames = names
    }
    function _unregisterTools() { toolNames.forEach(n => Tools.unregister(n)); toolNames = [] }

    function _onLine(line) {
        var m
        try { m = JSON.parse(line) } catch (e) { return }
        if (m.method === "event" && m.params) { event(m.params.type || "", m.params.data || {}); return }
        var cb = _pending[m.id]
        if (cb) { delete _pending[m.id]; cb(m.error || null, m.result) }
    }

    Socket {
        id: sock
        path: root.socketPath
        parser: SplitParser { splitMarker: "\n"; onRead: data => root._onLine(data) }
        onConnectedChanged: {
            if (connected) root._handshake()
            else { root.available = false; root._unregisterTools(); root._pending = ({}) }
        }
    }

    // Poll for the socket (the WM may start after us or restart).
    Timer { id: probe; interval: 15000; repeat: true; onTriggered: root._probe() }
}
