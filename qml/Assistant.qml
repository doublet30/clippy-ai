import QtQuick
import "js/providers.js" as P

// The whole desktop pet: character + bubble + brain, minus the OS window.
// Host (shell.qml) provides the transparent window, drag handling and click mask.
Item {
    id: root

    signal quit()
    signal moveBy(real dx, real dy)
    signal moveFinished()
    signal resetPosition()
    readonly property bool bubbleOpen: bubble.isOpen

    // hit-test rectangles (for the host's input mask)
    readonly property rect agentRect: Qt.rect(agent.x, agent.y, agent.width, agent.height)
    readonly property rect bubbleRect: bubble.isOpen
        ? Qt.rect(bubble.x + (bubble.width - bubble.bodyW) / 2, bubble.y + bubble.height - bubble.bodyH - bubble.tailH, bubble.bodyW, bubble.bodyH + bubble.tailH)
        : Qt.rect(0, 0, 0, 0)
    readonly property rect menuRect: menu.visible ? Qt.rect(menu.x, menu.y, menu.width, menu.height) : Qt.rect(0, 0, 0, 0)

    readonly property var thinkAnims: ["Thinking", "Processing", "Searching", "CheckingSomething", "Writing"]
    readonly property var talkAnims: ["Explain", "GestureLeft", "GestureRight", "GestureUp", "GestureDown"]
    property bool greeted: false
    property bool revealDone: true
    property bool replying: false
    property var _decide: null

    // ---------- public API (also used by IPC) ----------
    function ask(text) { _submit(text) }
    function say(text) { _present(text, true) }

    // ---------- pieces ----------
    Brain {
        id: brain
        onToolStarted: name => {
            var t = Tools.get(name)
            agent.loop(t && t.anim && agent.has(t.anim) ? [t.anim] : root.thinkAnims)
        }
        onConfirmRequested: (desc, decide) => {
            root._decide = decide
            bubble.fullText = desc; bubble.shownText = desc; bubble.mode = "confirm"
            agent.endLoop(); agent.playFirst(["Alert", "GetAttention"])
        }
        onAnswered: text => root._present(text, true)
        onFailed: msg => { agent.endLoop(); agent.playFirst(["Alert"]); root._present(msg, false) }
    }

    Agent {
        id: agent
        dir: Config.themeDir(Config.theme)
        pxScale: Config.scale
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        onSound: n => bank.play(n)
        onLoaded: {
            if (!root.greeted) {
                root.greeted = true
                playFirst(["Show", "Greeting"])
                playFirst(["Greeting", "Wave"])
                if (Config.greet) root._present("Hi! Click me and ask a question.", false, true)
            } else playFirst(["Show"])
        }
    }

    SoundBank { id: bank; dir: agent.dir; names: agent.soundNames; muted: Config.muted }

    Bubble {
        id: bubble
        anchors.horizontalCenter: agent.horizontalCenter
        y: agent.y - height + 26
        hint: brain.providerLabel + "  ·  Enter to ask  ·  Esc to close"
        onSubmitted: t => { clearInput(); root._submit(t) }
        onDismissed: root._dismiss()
        onClicked: root._openAsk()
        onConfirmed: ok => {
            var d = root._decide; root._decide = null
            bubble.mode = "thinking"; agent.loop(root.thinkAnims)
            if (d) d(ok)
        }
    }

    ContextMenu {
        id: menu
        z: 100      // above the agent's MouseArea, which would otherwise swallow clicks on overlapping items
        brains: [{ id: "auto", label: "Auto", ready: true }].concat(Config.providerIds.map(id => ({
            id: id, label: P.DEFAULTS[id].label, ready: P.resolve(id, Config.cfg.providers, Sys.env).ready })))
        themes: Config.themeNames()
        brain: Config.provider
        theme: Config.theme
        muted: Config.muted
        pin: Config.pin
        onChoose: (kind, v) => root.applyChoice(kind, v)
    }

    // Shared by the right-click menu and the IPC `select` call.
    function applyChoice(kind, v) {
        if (kind === "provider") {
            Config.save("provider", v)
            _present("Now using " + brain.providerLabel + ".", false)
        } else if (kind === "theme") Config.save("theme", v)
        else if (kind === "pin") Config.save("pin", v)
        else if (kind === "resetpos") root.resetPosition()
        else if (kind === "mute") { Config.save("muted", !Config.muted); if (Config.muted) Speech.stop() }
        else if (kind === "reset") { brain.reset(); _dismiss() }
        else if (kind === "animate") {
            var pool = agent.sprite.names().filter(n => !/^(Idle|Look|RestPose|Hide|Show)/.test(n))
            if (pool.length) agent.play(pool[Math.floor(Math.random() * pool.length)])
        } else if (kind === "quit") root.quit()
    }
    readonly property string statusText: "provider=" + Config.provider + " (" + brain.providerLabel + ") theme=" + Config.theme

    // ---------- interaction ----------
    MouseArea {
        x: agent.x; y: agent.y; width: agent.width; height: agent.height
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property real px: 0
        property real py: 0
        property bool dragged: false
        onPressed: m => { px = m.x; py = m.y; dragged = false }
        onPositionChanged: m => {
            if (!(m.buttons & Qt.LeftButton)) return
            if (!dragged && Math.abs(m.x - px) + Math.abs(m.y - py) < 6) return
            dragged = true
            root.moveBy(m.x - px, m.y - py)
        }
        onReleased: m => {
            if (dragged) { root.moveFinished(); return }
            if (m.button === Qt.RightButton) menu.openAt(agent.x + m.x, agent.y + m.y, root.width, root.height)
            else if (bubble.mode === "input") root._dismiss()
            else { menu.visible = false; root._openAsk() }
        }
    }

    // ---------- conversation flow ----------
    function _openAsk() {
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        agent.endLoop()
        agent.playFirst(["GetAttention", "Wave", "LookUp"])
        bubble.mode = "input"
    }

    function _dismiss() {
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        replying = false
        bubble.mode = "closed"
        agent.endLoop()
    }

    function _submit(text) {
        if (brain.busy) return
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        bubble.mode = "thinking"
        agent.endLoop(); agent.loop(thinkAnims)
        brain.ask(text)
    }

    // Show text in the bubble, paste it in word by word, optionally speak it.
    function _present(text, talk, quiet) {
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        agent.endLoop()
        words = text.split(/(\s+)/)
        wordIdx = 0
        bubble.fullText = text; bubble.shownText = ""; bubble.mode = "speak"
        revealDone = false
        replying = true
        var spoke = talk && Speech.speak(text, () => { speechDone = true; if (revealDone) _finish(); else revealTimer.interval = 25 })
        speechDone = !spoke
        revealTimer.interval = spoke ? Speech.msPerWord / 2 : (talk ? 70 : 45)
        revealTimer.start()
        if (talk) agent.loop(talkAnims)
        else if (!quiet) agent.endLoop()
    }

    property var words: []
    property int wordIdx: 0
    property bool speechDone: true

    Timer {
        id: revealTimer
        repeat: true
        onTriggered: {
            // two tokens per tick: a word and the whitespace after it
            var add = root.words.slice(root.wordIdx, root.wordIdx + 2).join("")
            root.wordIdx += 2
            bubble.shownText += add
            if (root.wordIdx >= root.words.length) {
                stop(); bubble.shownText = bubble.fullText; root.revealDone = true
                if (root.speechDone) root._finish()
            }
        }
    }

    function _finish() {
        replying = false
        agent.endLoop()
        autoClose.restart()
    }
    Timer { id: autoClose; interval: 22000; onTriggered: if (bubble.mode === "speak") root._dismiss() }
}
