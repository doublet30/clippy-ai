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
    // A response bubble is display-only and must stay at the normal widget
    // layer. Only a live text prompt needs a keyboard-focusable surface.
    readonly property bool inputActive: bubble.mode === "input"

    // hit-test rectangles (for the host's input mask). VisualAgent normalizes
    // sprite and Canvas renderer geometry, and a hidden Circle deliberately
    // has no input region so the desktop remains fully click-through.
    readonly property rect agentRect: visual.displayed
        ? Qt.rect(visual.x, visual.y, visual.width, visual.height)
        : Qt.rect(0, 0, 0, 0)
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
    // IPC commands are serialised so a prompt sent while an LLM answer is in
    // progress is retained rather than discarded by Brain's busy guard.
    property var commandQueue: []
    property bool commandDispatching: false

    // ---------- public API (also used by IPC) ----------
    function ask(text) { _submit(text) }
    function say(text) { _present(text, true) }
    function enqueueCommand(agentName, prompt, animationName) {
        commandQueue = commandQueue.concat([{
            agent: agentName || "",
            prompt: prompt || "",
            animation: animationName || ""
        }])
        _dispatchNextCommand()
    }
    function _dispatchNextCommand() {
        if (brain.busy || replying || commandDispatching || commandQueue.length === 0)
            return
        const command = commandQueue[0]
        commandQueue = commandQueue.slice(1)
        if (command.agent.length > 0 && Config.themeNames().indexOf(command.agent) >= 0)
            applyChoice("theme", command.agent)
        if (command.animation.length > 0)
            playAnimation(command.animation)
        if (command.prompt.length > 0) {
            // Applying a theme replaces the sprite on QML's next turn.
            commandDispatching = true
            Qt.callLater(function() {
                root.commandDispatching = false
                root._submit(command.prompt)
            })
        } else {
            Qt.callLater(root._dispatchNextCommand)
        }
    }
    function playAnimation(name) {
        if (name.length > 0 && visual.has(name))
            visual.play(name)
    }

    // ---------- pieces ----------
    Brain {
        id: brain
        onToolStarted: name => {
            var t = Tools.get(name)
            visual.loop(t && t.anim && visual.has(t.anim) ? [t.anim] : root.thinkAnims)
        }
        onConfirmRequested: (desc, decide) => {
            root._decide = decide
            bubble.fullText = desc; bubble.shownText = desc; bubble.mode = "confirm"
            visual.endLoop(); visual.playFirst(["Alert", "GetAttention"])
        }
        onAnswered: text => root._present(text, true)
        onFailed: msg => { visual.endLoop(); visual.playFirst(["Alert"]); root._present(msg, false) }
    }

    VisualAgent {
        id: visual
        dir: Config.themeDir(Config.theme)
        pxScale: Config.scale
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        onSound: n => bank.play(n)
        onLoaded: {
            // Circle AI begins hidden and appears only in response to a
            // command/request.  Keep the traditional greeting exclusively
            // for sprite agents so its idle behaviour remains intentional.
            if (isCircle)
                return
            if (!root.greeted) {
                root.greeted = true
                playFirst(["Show", "Greeting"])
                playFirst(["Greeting", "Wave"])
                if (Config.greet) root._present("Hi! Click me and ask a question.", false, true)
            } else playFirst(["Show"])
        }
    }

    SoundBank { id: bank; dir: visual.dir; names: visual.soundNames; muted: Config.muted }

    Bubble {
        id: bubble
        anchors.horizontalCenter: visual.horizontalCenter
        y: visual.y - height + 26
        hint: brain.providerLabel + "  ·  Enter to ask  ·  Esc to close"
        onSubmitted: t => { clearInput(); root._submit(t) }
        onDismissed: root._dismiss()
        onClicked: root._openAsk()
        onConfirmed: ok => {
            var d = root._decide; root._decide = null
            bubble.mode = "thinking"; visual.loop(root.thinkAnims)
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
            var pool = visual.randomAnimationNames()
            if (pool.length) visual.play(pool[Math.floor(Math.random() * pool.length)])
        } else if (kind === "quit") root.quit()
    }
    readonly property string statusText: "provider=" + Config.provider + " (" + brain.providerLabel + ") theme=" + Config.theme + " renderer=" + visual.rendererType

    // ---------- interaction ----------
    MouseArea {
        x: visual.x; y: visual.y; width: visual.width; height: visual.height
        visible: visual.displayed
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
            if (m.button === Qt.RightButton) menu.openAt(visual.x + m.x, visual.y + m.y, root.width, root.height)
            else if (bubble.mode === "input") root._dismiss()
            else { menu.visible = false; root._openAsk() }
        }
    }

    // ---------- conversation flow ----------
    function _openAsk() {
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        visual.endLoop()
        visual.playFirst(["GetAttention", "Wave", "LookUp"])
        bubble.mode = "input"
    }

    function _dismiss(preserveCircleTimeout) {
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        replying = false
        bubble.mode = "closed"
        // The Circle renderer starts its own 20-second hide countdown when a
        // response settles.  Do not restart it merely because the matching
        // response bubble closes at the same moment.
        if (!visual.isCircle || !preserveCircleTimeout)
            visual.endLoop()
    }

    // Called by the compositor-side outside-click bridge. Keep this public
    // and deliberately narrow: a notification/answer remains visible, but a
    // text entry immediately gives focus and stacking back to the active app.
    function dismissForFocusLoss() {
        if (bubble.mode === "input")
            _dismiss()
    }

    function _submit(text) {
        if (brain.busy) return
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        bubble.mode = "thinking"
        if (visual.isCircle)
            visual.beginProcessing()
        else {
            visual.endLoop()
            visual.loop(thinkAnims)
        }
        brain.ask(text)
    }

    // Show text in the bubble, paste it in word by word, optionally speak it.
    function _present(text, talk, quiet) {
        Speech.stop(); revealTimer.stop(); autoClose.stop()
        if (visual.isCircle)
            visual.beginSpeaking()
        else
            visual.endLoop()
        words = text.split(/(\s+)/)
        wordIdx = 0
        bubble.fullText = text; bubble.shownText = ""; bubble.mode = "speak"
        revealDone = false
        replying = true
        var spoke = talk && Speech.speak(text, () => { speechDone = true; if (revealDone) _finish(); else revealTimer.interval = 25 })
        speechDone = !spoke
        revealTimer.interval = spoke ? Speech.msPerWord / 2 : (talk ? 70 : 45)
        revealTimer.start()
        if (!visual.isCircle) {
            if (talk) visual.loop(talkAnims)
            else if (!quiet) visual.endLoop()
        }
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
        visual.settle()
        autoClose.restart()
        _dispatchNextCommand()
    }
    Timer {
        id: autoClose
        interval: visual.isCircle ? 20000 : 22000
        onTriggered: if (bubble.mode === "speak") root._dismiss(visual.isCircle)
    }
}
