pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// User config: ~/.config/revvy-ai/config.json  (see docs/CONFIG.md)
// Mutable UI choices (provider/theme/mute) persist in state.json beside it.
Singleton {
    id: root

    readonly property string dir: Sys.home() + "/.config/revvy-ai"

    property var cfg: ({})
    property var state: ({})

    property string provider: state.provider || cfg.provider || "auto"
    property string wantedTheme: state.theme || cfg.theme || "tux"
    // Falls back to the first installed theme if the wanted one isn't installed (theme packages are optional).
    readonly property string theme: {
        var n = themeNames()
        return (n.length === 0 || n.indexOf(wantedTheme) >= 0) ? wantedTheme : n[0]
    }
    // Stacking: "above" other windows (default) or "below" them (above the wallpaper only)
    property string pin: state.pin || cfg.pin || "above"
    property bool muted: state.muted !== undefined ? state.muted : (cfg.muted || false)
    property real scale: cfg.scale || 2
    property string location: cfg.location || ""            // weather default; empty = geo-IP
    property string terminalPolicy: cfg.terminal || "confirm" // "confirm" | "allow" | "deny"
    // "auto": desktop apps and safe files open directly, anything else asks first; "confirm": always ask; "allow": never ask
    property string launchPolicy: cfg.launch || "auto"
    property string units: cfg.units || (Qt.locale().measurementSystem === Locale.MetricSystem ? "metric" : "imperial")
    property bool useRouter: cfg.router !== false      // answer common requests without the model (best for small models)
    property bool greet: cfg.greeting !== false
    // Visual-only chat suppression. The assistant can still process CLI/menu
    // prompts and speak replies; mandatory approval prompts remain visible.
    property bool hideChatBubble: cfg.hideChatBubble === true
    property var tts: cfg.tts || ({})
    property string userName: cfg.userName || ""

    readonly property var providerIds: ["openai", "anthropic", "gemini", "llama", "grok", "local"]
    property var systemThemes: []  // [{name, dir}] shipped next to this config (themes/ in the install dir)
    property var userThemes: []   // [{name, dir}] discovered in ~/.config/revvy-ai/themes

    function themeDir(name) {
        for (var i = 0; i < userThemes.length; i++)
            if (userThemes[i].name === name) return userThemes[i].dir
        for (var j = 0; j < systemThemes.length; j++)
            if (systemThemes[j].name === name) return systemThemes[j].dir
        return Quickshell.shellPath("themes/" + name)
    }
    function themeNames() {
        var r = systemThemes.map(t => t.name)
        userThemes.forEach(t => { if (r.indexOf(t.name) < 0) r.push(t.name) })
        return r
    }

    function save(key, value) {
        var s = Object.assign({}, state)
        if (value === null || value === undefined) delete s[key]; else s[key] = value
        state = s
        stateFile.setText(JSON.stringify(s, null, 2))
    }

    FileView {
        id: cfgFile
        path: root.dir + "/config.json"
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { root.cfg = JSON.parse(text()) } catch (e) { console.warn("config.json:", e) } }
    }
    FileView {
        id: stateFile
        path: root.dir + "/state.json"
        blockLoading: true
        watchChanges: true      // the config tool clears stale overrides when you save there
        onFileChanged: reload()
        onLoaded: { try { root.state = JSON.parse(text()) } catch (e) {} }
    }

    function _scan(dir, assign) {
        Sys.run(["sh", "-c", "for d in '" + dir + "'/*/; do [ -f \"$d/agent.json\" ] && echo \"${d%/}\"; done"],
            (c, o) => {
                var r = []
                o.split("\n").forEach(l => { l = l.trim(); if (l) r.push({ name: l.split("/").pop(), dir: l }) })
                assign(r)
            })
    }

    Component.onCompleted: {
        _scan(Quickshell.shellPath("themes"), r => { systemThemes = r })
        Sys.run(["sh", "-c", "mkdir -p '" + dir + "/themes'; for d in '" + dir + "'/themes/*/; do [ -f \"$d/agent.json\" ] && echo \"${d%/}\"; done"],
            (c, o) => {
                var r = []
                o.split("\n").forEach(l => { l = l.trim(); if (l) r.push({ name: l.split("/").pop(), dir: l }) })
                userThemes = r
            })
    }
}
