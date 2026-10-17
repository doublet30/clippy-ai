import QtQuick

// Port of clippy.js Animator (pithings/clippy) - frame stepping, weighted
// branching and exitBranch semantics are preserved; DOM background-position
// became Image offsets inside a clipped Item.
Item {
    id: root

    property var spec: ({ animations: {}, framesize: [124, 93], overlayCount: 1 })
    property url mapSource
    property real pxScale: 2
    // Themes drawn at higher resolution (vector mascots) set sheetScale>1: sheet px per logical px.
    readonly property real sheetScale: spec.sheetScale || 1
    readonly property real imgScale: pxScale / sheetScale

    readonly property int fw: spec.framesize ? spec.framesize[0] : 124
    readonly property int fh: spec.framesize ? spec.framesize[1] : 93
    width: fw * pxScale
    height: fh * pxScale
    clip: true

    // Animation state (private-ish)
    property var _anim: null
    property var _frame: null
    property int _idx: 0
    property bool _exiting: false
    property var _cb: null
    property string current: ""
    property var _images: []    // [[x,y], ...] for the visible frame

    signal soundPlayed(string name)

    readonly property int stateWaiting: 1
    readonly property int stateExited: 0

    function has(name) { return !!(spec.animations && spec.animations[name]) }
    function names() { return Object.keys(spec.animations || {}) }
    function exitAnimation() { _exiting = true }
    function stop() { timer.stop(); _cb = null }

    // Show frame 0 of an animation without running it (rest pose).
    function showStatic(name) {
        timer.stop(); _cb = null; current = ""
        if (!has(name)) return
        _images = spec.animations[name].frames[0].images || []
    }

    // cb(name, state) with stateWaiting / stateExited
    function play(name, cb) {
        _exiting = false
        if (!has(name)) return false
        _anim = spec.animations[name]
        current = name
        _idx = 0
        _frame = null
        _cb = cb || null
        timer.stop()
        _step()
        return true
    }

    function _next() {
        if (!_anim) return undefined
        if (!_frame) return 0
        var f = _frame
        if (_exiting && f.exitBranch !== undefined) return f.exitBranch
        if (f.branching) {
            var rnd = Math.random() * 100, b = f.branching.branches
            for (var i = 0; i < b.length; i++) {
                if (rnd <= b[i].weight) return b[i].frameIndex
                rnd -= b[i].weight
            }
        }
        return _idx + 1
    }

    function _step() {
        if (!_anim) return
        var last = _anim.frames.length - 1
        var ni = Math.min(_next(), last)
        var changed = !_frame || _idx !== ni
        _idx = ni
        var atLast = _idx >= last
        // Holding at the end of an exit-branching animation re-uses the previous frame's branches.
        if (!_frame || !(atLast && _anim.useExitBranching)) _frame = _anim.frames[_idx]
        _images = _frame.images || []
        if (_frame.sound) soundPlayed(_frame.sound)

        var waiting = atLast && _anim.useExitBranching && !_exiting
        if (_cb && changed && atLast) {
            if (!waiting) { _finish(); return }
            _cb(current, stateWaiting)
        }
        timer.interval = Math.max(_frame.duration, 16)
        timer.restart()
    }

    // Last frame reached: report EXITED and stop stepping (frame stays on screen).
    function _finish() {
        var cb = _cb
        _cb = null
        _anim = null     // stops _step from advancing further
        timer.stop()
        cb(current, stateExited)
    }

    Timer { id: timer; onTriggered: root._step() }

    Repeater {
        model: root.spec.overlayCount || 1
        Image {
            required property int index
            visible: index < root._images.length
            source: root.mapSource
            smooth: root.sheetScale > 1
            mipmap: root.sheetScale > 1
            asynchronous: false
            cache: true
            scale: root.imgScale
            transformOrigin: Item.TopLeft
            x: visible ? -root._images[index][0] * root.imgScale : 0
            y: visible ? -root._images[index][1] * root.imgScale : 0
        }
    }
}
