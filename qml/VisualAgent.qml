import QtQuick
import Quickshell.Io

// A renderer-aware adapter.  Classic themes still go through Agent.qml and
// CharSprite.qml; renderer plug-ins declare their type in agent.json and never
// touch the sprite path.  Assistant talks only to this stable surface.
Item {
    id: root

    property string dir: ""
    property real pxScale: 2
    property var manifest: ({})
    property bool manifestLoaded: false
    readonly property string rendererType: manifest && manifest.renderer === "circle-ai" ? "circle-ai" : "sprite"
    readonly property bool isCircle: manifestLoaded && rendererType === "circle-ai"
    readonly property bool ready: isCircle ? true : sprite.ready
    readonly property var soundNames: isCircle ? [] : sprite.soundNames
    readonly property var animationNames: manifest && manifest.animations ? Object.keys(manifest.animations) : []
    readonly property var visualItem: isCircle ? circle : sprite
    readonly property bool displayed: isCircle ? circle.displayed : true

    width: isCircle ? circle.width : sprite.width
    height: isCircle ? circle.height : sprite.height

    signal sound(string name)
    signal loaded()

    function firstOf(list) {
        for (var i = 0; i < list.length; ++i)
            if (has(list[i]))
                return list[i]
        return ""
    }

    function has(name) {
        if (isCircle)
            return animationNames.indexOf(name) >= 0
        return sprite.has(name)
    }

    function play(name, cb) {
        if (!isCircle)
            return sprite.play(name, cb)
        if (!has(name)) {
            if (cb)
                Qt.callLater(cb)
            return false
        }
        if (name === "Hide")
            circle.hide()
        else if (name === "Show" || name === "Greeting" || name === "Idle" || name === "RestPose")
            circle.showIdle()
        else if (/^(Explain|Gesture|Speaking)/.test(name))
            circle.beginActivity("speaking")
        else
            circle.beginActivity("processing")
        if (cb)
            Qt.callLater(cb)
        return true
    }

    function playFirst(list, cb) {
        var choice = firstOf(list)
        return choice ? play(choice, cb) : (cb && Qt.callLater(cb), false)
    }

    function loop(list) {
        if (isCircle) {
            // The semantic sets Assistant passes are distinct: response
            // gestures mean speaking; every other loop means processing.
            var speaking = list.some(function(name) { return /^(Explain|Gesture|Speaking)/.test(name) })
            circle.beginActivity(speaking ? "speaking" : "processing")
        } else {
            sprite.loop(list)
        }
    }

    function endLoop() {
        if (isCircle)
            circle.settle()
        else
            sprite.endLoop()
    }

    function beginProcessing() {
        if (isCircle)
            circle.beginActivity("processing")
    }

    function beginSpeaking() {
        if (isCircle)
            circle.beginActivity("speaking")
    }

    function settle() {
        if (isCircle)
            circle.settle()
        else
            sprite.endLoop()
    }

    function randomAnimationNames() {
        if (isCircle)
            return animationNames.filter(function(name) { return !/^(Idle|RestPose|Hide|Show|Greeting)$/.test(name) })
        return sprite.names().filter(function(name) { return !/^(Idle|Look|RestPose|Hide|Show)/.test(name) })
    }

    onDirChanged: {
        manifestLoaded = false
        manifest = ({})
    }

    FileView {
        id: manifestFile
        path: root.dir ? root.dir + "/agent.json" : ""
        blockLoading: true
        onLoaded: {
            try {
                root.manifest = JSON.parse(text())
                root.manifestLoaded = true
                if (root.manifest.renderer === "circle-ai")
                    Qt.callLater(function() { root.loaded() })
            } catch (e) {
                root.manifest = ({})
                root.manifestLoaded = true
                console.warn("Revvy appearance manifest failed to load:", root.dir, e)
            }
        }
    }

    Agent {
        id: sprite
        // Do not let a plug-in manifest enter Agent.qml: it expects a sprite
        // map and frame array and deliberately knows nothing about Canvas.
        dir: root.manifestLoaded && !root.isCircle ? root.dir : ""
        pxScale: root.pxScale
        visible: !root.isCircle
        onSound: (name) => root.sound(name)
        onLoaded: {
            if (!root.isCircle)
                root.loaded()
        }
    }

    CircleAiAnimation {
        id: circle
        anchors.centerIn: parent
        pxScale: root.pxScale
        enabledForHost: root.isCircle
        appearanceEffects: root.manifest && root.manifest.appearanceEffects
                           ? root.manifest.appearanceEffects : ["fade"]
    }
}
