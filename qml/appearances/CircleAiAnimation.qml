import QtQuick

// Renderer plug-in for the Circle AI appearance.  It intentionally only
// depends on QtQuick: unlike the standalone demo it needs no ApplicationWindow,
// Python bridge, controls, or audio capture process.  VisualAgent.qml owns the
// renderer contract and chooses this component only for a theme that declares
// `renderer: "circle-ai"` in its agent.json manifest.
Item {
    id: root

    // Keep the footprint consistent with normal Agent themes: their logical
    // frame is normally 120 px, multiplied by Revvy's existing scale setting.
    property real pxScale: 2
    implicitWidth: Math.max(84, Math.round(120 * pxScale))
    implicitHeight: implicitWidth
    width: implicitWidth
    height: implicitHeight

    // Visual renderer API consumed by VisualAgent.
    property bool enabledForHost: true
    property string state: "hidden" // hidden | appearing | processing | speaking | idle | hiding
    property var appearanceEffects: ["fade"]
    property string selectedAppearance: ""
    property string pendingState: ""
    property int idleTimeout: 20000
    property color firstColor: "#00c8ff"
    property color secondColor: "#ff8000"
    readonly property bool displayed: enabledForHost && state !== "hidden"
    readonly property bool active: state === "processing" || state === "speaking"

    // The only current appearance plug-in is fade.  Choosing from this array
    // rather than naming it in the request path makes later plug-ins additive.
    function chooseAppearance() {
        if (!appearanceEffects || appearanceEffects.length === 0)
            return "fade"
        return appearanceEffects[Math.floor(Math.random() * appearanceEffects.length)]
    }

    function beginActivity(nextState) {
        var target = nextState === "speaking" ? "speaking" : "processing"
        idleTimer.stop()
        hideAnimation.stop()
        if (state === "hidden" || state === "hiding") {
            selectedAppearance = chooseAppearance()
            pendingState = target
            state = "appearing"
            opacity = 0
            scale = 0.92
            // Future plug-ins can choose their own transition here.  Today
            // there is one safe, deterministic fade implementation.
            fadeIn.restart()
        } else {
            fadeIn.stop()
            opacity = 1
            scale = 1
            state = target
            ring.requestPaint()
        }
    }

    // Show the calm, complete circle without a processing animation.  This is
    // useful for `--animation Show` and is also the settled post-response state.
    function showIdle() {
        idleTimer.stop()
        hideAnimation.stop()
        if (state === "hidden" || state === "hiding") {
            selectedAppearance = chooseAppearance()
            pendingState = "idle"
            state = "appearing"
            opacity = 0
            scale = 0.92
            fadeIn.restart()
        } else {
            fadeIn.stop()
            opacity = 1
            scale = 1
            state = "idle"
            idleTimer.restart()
            ring.requestPaint()
        }
    }

    // A completed request settles to the full circle for exactly the normal
    // idle grace period, then fades away.  An already hidden renderer remains
    // hidden: opening and dismissing a prompt must not make it appear.
    function settle() {
        if (state === "hidden")
            return
        fadeIn.stop()
        hideAnimation.stop()
        opacity = 1
        scale = 1
        state = "idle"
        idleTimer.restart()
        ring.requestPaint()
    }

    function hide() {
        if (state === "hidden" || state === "hiding")
            return
        idleTimer.stop()
        fadeIn.stop()
        state = "hiding"
        hideAnimation.restart()
    }

    function reset() {
        idleTimer.stop()
        fadeIn.stop()
        hideAnimation.stop()
        pendingState = ""
        state = "hidden"
        opacity = 0
        scale = 0.92
        ring.requestPaint()
    }

    visible: displayed
    onStateChanged: ring.requestPaint()
    onEnabledForHostChanged: {
        if (!enabledForHost)
            reset()
    }

    ParallelAnimation {
        id: fadeIn
        NumberAnimation {
            target: root
            property: "opacity"
            from: 0
            to: 1
            duration: 260
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root
            property: "scale"
            from: 0.92
            to: 1
            duration: 300
            easing.type: Easing.OutCubic
        }
        onFinished: {
            if (root.state !== "appearing")
                return
            root.state = root.pendingState || "idle"
            root.pendingState = ""
            if (root.state === "idle")
                idleTimer.restart()
            ring.requestPaint()
        }
    }

    ParallelAnimation {
        id: hideAnimation
        NumberAnimation {
            target: root
            property: "opacity"
            from: 1
            to: 0
            duration: 360
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: root
            property: "scale"
            from: 1
            to: 0.92
            duration: 360
            easing.type: Easing.InCubic
        }
        onFinished: {
            if (root.state === "hiding") {
                root.state = "hidden"
                root.opacity = 0
                root.scale = 0.92
            }
        }
    }

    Timer {
        id: idleTimer
        interval: root.idleTimeout
        repeat: false
        onTriggered: root.hide()
    }

    property real phaseA: 0
    property real phaseB: 0
    property real elapsed: 0
    property real glow: 0.32
    // Match the defaults from the standalone Circle AI renderer.  Keep these
    // named rather than baking their values into Canvas math so the appearance
    // remains easy to tune without changing its state/lifecycle contract.
    property real speedMultiplier: 7.52
    property real peakHeightScale: 0.58
    property real spikeDipScale: 2.10
    property real spacingRangeScale: 2.69
    property real phaseSpeedA: 1.0
    property real phaseSpeedB: 1.0
    property real targetPhaseSpeedA: 1.0
    property real targetPhaseSpeedB: 1.0
    property real driftElapsed: 0.0
    property real nextDriftAt: 0.85

    function naturalDrift() {
        // Each counter-rotating ring gets a separate, slowly varying tempo.
        // This is the same gentle variation used by the original Circle AI
        // animation; interpolating toward it prevents jitter.
        targetPhaseSpeedA = 0.88 + Math.random() * 0.24
        targetPhaseSpeedB = 0.84 + Math.random() * 0.30
        nextDriftAt = 0.72 + Math.random() * 0.96
        driftElapsed = 0.0
    }

    // The Canvas is repainted only for active processing/speaking. Idle and
    // hidden states have no running timer and consume no background CPU.
    Timer {
        interval: 25
        repeat: true
        running: root.enabledForHost && root.active
        onTriggered: {
            var activitySpeed = root.state === "speaking" ? 1.32 : 1.0
            root.elapsed += interval / 1000
            root.driftElapsed += interval / 1000
            if (root.driftElapsed >= root.nextDriftAt)
                root.naturalDrift()

            root.phaseSpeedA += (root.targetPhaseSpeedA - root.phaseSpeedA) * 0.018
            root.phaseSpeedB += (root.targetPhaseSpeedB - root.phaseSpeedB) * 0.016
            const frameScale = interval / 16
            root.phaseA += 0.02375 * frameScale * root.phaseSpeedA
                         * root.speedMultiplier * activitySpeed
            root.phaseB -= 0.0175 * frameScale * root.phaseSpeedB
                         * root.speedMultiplier * activitySpeed
            root.glow = 0.5 + 0.5 * Math.sin(root.elapsed * 1.35)
            ring.requestPaint()
        }
    }

    Canvas {
        id: ring
        anchors.fill: parent
        antialiasing: true
        renderTarget: Canvas.Image

        function unitNoise(value, seed) {
            const hashed = Math.sin(value * 127.1 + seed * 311.7) * 43758.5453123
            return hashed - Math.floor(hashed)
        }

        function peakSpacingPhase(angle, phase, count, seed) {
            // Low-frequency integer harmonics stretch and compress the
            // distance between peaks while keeping the wave closed at 360°.
            const spacingWarp = (0.78 * Math.sin(5 * angle + seed * 1.31 - phase * 0.09)
                + 0.46 * Math.sin(9 * angle - seed * 2.17 + phase * 0.06)
                + 0.22 * Math.sin(17 * angle + seed * 4.09 - phase * 0.035))
                * root.spacingRangeScale
            return count * angle + phase + spacingWarp
        }

        function peakAmplitude(wavePhase, seed) {
            const fullTurn = 2 * Math.PI
            const crestIndex = Math.floor((wavePhase + Math.PI / 2) / fullTurn)
            const troughIndex = Math.floor((wavePhase + 3 * Math.PI / 2) / fullTurn)
            const crestTip = Math.pow(Math.max(0, Math.sin(wavePhase)), 8)
            const troughTip = Math.pow(Math.max(0, -Math.sin(wavePhase)), 8)
            const crestOffset = (unitNoise(crestIndex, seed) - 0.5) * 0.96
                * root.spikeDipScale
            const troughOffset = (unitNoise(troughIndex, seed + 9.73) - 0.5) * 0.96
                * root.spikeDipScale
            return 1 + crestTip * crestOffset + troughTip * troughOffset
        }

        function path(ctx, cx, cy, radius, amplitude, phase, count, seed) {
            // The widget is physically smaller than the original 760px demo;
            // 300 samples preserve its curve without wasting paint time.
            const steps = 300
            ctx.beginPath()
            for (let index = 0; index <= steps; ++index) {
                const angle = index * 2 * Math.PI / steps
                const wavePhase = peakSpacingPhase(angle, phase, count, seed)
                const individual = peakAmplitude(wavePhase, seed)
                const wobble = Math.sin(wavePhase) * individual
                    + 0.11 * Math.sin((count + 5) * angle - phase * 0.69 + seed)
                    + 0.055 * Math.sin((count - 7) * angle + phase * 0.43 + seed * 2)
                const radial = radius + amplitude * wobble
                const x = cx + radial * Math.cos(angle)
                const y = cy + radial * Math.sin(angle)
                if (index === 0)
                    ctx.moveTo(x, y)
                else
                    ctx.lineTo(x, y)
            }
            ctx.closePath()
        }

        function drawWave(ctx, cx, cy, radius, amplitude, phase, count, seed, color, alpha) {
            const rgb = [Math.round(color.r * 255), Math.round(color.g * 255),
                         Math.round(color.b * 255)].join(",")
            const base = Math.max(1.7, radius * 0.007)
            for (let pass = 0; pass < 3; ++pass) {
                path(ctx, cx, cy, radius, amplitude, phase, count, seed)
                ctx.lineWidth = pass === 0 ? base * 7
                              : pass === 1 ? base * 3 : base
                ctx.strokeStyle = pass === 0 ? "rgba(" + rgb + "," + (0.075 * alpha) + ")"
                                : pass === 1 ? "rgba(" + rgb + "," + (0.20 * alpha) + ")"
                                : "rgba(" + rgb + "," + (0.98 * alpha) + ")"
                ctx.stroke()
            }
        }

        function drawFlatRing(ctx, cx, cy, radius, color, alpha) {
            const rgb = [Math.round(color.r * 255), Math.round(color.g * 255),
                         Math.round(color.b * 255)].join(",")
            const diameter = Math.min(width, height)
            ctx.beginPath()
            ctx.arc(cx, cy, radius, 0, 2 * Math.PI)
            ctx.lineWidth = Math.max(2.4, diameter * 0.078)
            ctx.strokeStyle = "rgba(" + rgb + "," + (0.10 * alpha) + ")"
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(cx, cy, radius, 0, 2 * Math.PI)
            ctx.lineWidth = Math.max(0.7, diameter * 0.017)
            ctx.strokeStyle = "rgba(" + rgb + "," + (0.98 * alpha) + ")"
            ctx.stroke()
        }

        onPaint: {
            const context = getContext("2d")
            context.clearRect(0, 0, width, height)
            const diameter = Math.min(width, height)
            const cx = width / 2
            const cy = height / 2
            const radius = diameter * 0.325
            if (!root.active) {
                // A calm, complete dual-colour circle is deliberately used
                // for appearance and idle: animation starts only once work
                // begins, so a request has a clear visual transition.
                drawFlatRing(context, cx, cy, radius + diameter * 0.010, root.firstColor, 1)
                drawFlatRing(context, cx, cy, radius - diameter * 0.010, root.secondColor, 0.80)
                return
            }
            const amplitude = radius * 0.074 * root.peakHeightScale
            const separation = radius * 0.012
            drawWave(context, cx, cy, radius + separation, amplitude,
                     root.phaseA, 42, 0.8, root.firstColor, 1)
            drawWave(context, cx, cy, radius - separation, amplitude * 0.88,
                     root.phaseB, 47, 1.4, root.secondColor, 1)
        }
    }

    // The centre mark remains scalable and never escapes the ring at small
    // sizes.  A slow halo is visible only while the renderer is active.
    Item {
        id: mark
        anchors.fill: parent
        property real fontSize: Math.max(8, Math.min(width, height) * 0.31)
        property real spacing: -Math.min(14, fontSize * 0.20)
        property real pulse: root.active ? root.glow : 0.28
        Row {
            anchors.centerIn: parent
            spacing: parent.spacing
            scale: 1.10 + parent.pulse * 0.05
            opacity: 0.14 + parent.pulse * 0.17
            Text {
                text: "A"
                color: root.firstColor
                font.family: "Quicksand"
                font.pixelSize: mark.fontSize
                font.weight: Font.Black
                font.italic: true
            }
            Text {
                text: "i"
                color: root.secondColor
                font.family: "Quicksand"
                font.pixelSize: mark.fontSize
                font.weight: Font.Black
                font.italic: true
            }
        }
        Row {
            anchors.centerIn: parent
            spacing: parent.spacing
            Text {
                text: "A"
                color: root.firstColor
                font.family: "Quicksand"
                font.pixelSize: mark.fontSize
                font.weight: Font.Black
                font.italic: true
            }
            Text {
                text: "i"
                color: root.secondColor
                font.family: "Quicksand"
                font.pixelSize: mark.fontSize
                font.weight: Font.Black
                font.italic: true
            }
        }
    }
}
