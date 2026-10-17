import QtQuick
import Quickshell.Io

// Port of clippy.js Agent + Queue: an action queue on top of Sprite, plus
// "loop" states (thinking / speaking) and random idle behaviour.
Item {
    id: root

    property string dir                 // theme directory (agent.json, map.png, sounds/)
    property real pxScale: 2
    property var spec: null
    readonly property bool ready: spec !== null
    readonly property var soundNames: spec ? (spec.sounds || []) : []
    readonly property alias sprite: sprite

    width: sprite.width
    height: sprite.height

    signal sound(string name)
    signal loaded()

    // ---- state ----
    property var queue: []
    property bool busy: false
    property bool idling: false
    property bool waiting: false
    property var loopList: []
    property string restName: ""

    function has(n) { return ready && sprite.has(n) }
    function firstOf(list) { for (var i = 0; i < list.length; i++) if (has(list[i])) return list[i]; return "" }

    // Queue an animation; cb fires when it has finished.
    function play(name, cb) { if (!has(name)) { if (cb) Qt.callLater(cb); return false }; queue = queue.concat([{ name: name, cb: cb }]); _wake(); return true }
    function playFirst(list, cb) { var n = firstOf(list); return n ? play(n, cb) : (cb && Qt.callLater(cb), false) }

    // Repeat random animations from list until endLoop().
    function loop(list) {
        loopList = list.filter(n => has(n))
        _wake()
    }
    function endLoop() { loopList = []; _wake() }
    function clearQueue() { queue = []; loopList = []; _wake() }

    function _wake() {
        if (!ready) return
        if (busy && (idling || waiting || loopList.length === 0 && queue.length)) { holdTimer.stop(); waiting = false; sprite.exitAnimation() }
        _pump()
    }

    function _pick(list) { return list[Math.floor(Math.random() * list.length)] }

    function _pump() {
        if (!ready || busy) return
        idleTimer.stop()
        if (queue.length) { var e = queue[0]; queue = queue.slice(1); _run(e.name, e.cb, false); return }
        if (loopList.length) { _run(_pick(loopList), null, false); return }
        sprite.showStatic(restName)
        idleTimer.interval = 3500 + Math.random() * 6000
        idleTimer.restart()
    }

    function _run(name, cb, isIdle) {
        busy = true; idling = isIdle; waiting = false
        var ok = sprite.play(name, (n, st) => {
            if (st === sprite.stateWaiting) {
                waiting = true
                holdTimer.interval = loopList.length ? 1400 : 2200
                holdTimer.restart()
            } else {
                busy = false; idling = false; waiting = false; holdTimer.stop()
                if (cb) cb()
                _pump()
            }
        })
        if (!ok) { busy = false; if (cb) cb(); Qt.callLater(_pump) }
    }

    Timer { id: holdTimer; onTriggered: { root.waiting = false; sprite.exitAnimation() } }
    Timer {
        id: idleTimer
        onTriggered: {
            var pool = sprite.names().filter(n => /^(Idle|Look)/.test(n) && n !== "IdleSnooze")
            if (pool.length) root._run(root._pick(pool), null, true)
        }
    }

    CharSprite {
        id: sprite
        spec: root.spec || ({ animations: {}, framesize: [124, 93], overlayCount: 1 })
        mapSource: root.dir ? "file://" + root.dir + "/map.png" : ""
        pxScale: root.pxScale
        onSoundPlayed: n => root.sound(n)
    }

    FileView {
        id: file
        path: root.dir ? root.dir + "/agent.json" : ""
        blockLoading: true
        onLoaded: {
            try {
                var d = JSON.parse(text())
                sprite.stop()
                root.restName = ["RestPose", "Idle1_1"].find(n => d.animations[n]) || Object.keys(d.animations)[0]
                root.queue = []; root.loopList = []; root.busy = false
                root.spec = d
                root.loaded()
                root._pump()
            } catch (e) { console.warn("theme load failed:", root.dir, e) }
        }
    }
}
