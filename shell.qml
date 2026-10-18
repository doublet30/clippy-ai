//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "qml"

// Entry point:  quickshell -p /path/to/revvy-ai
// The same `Assistant` item can be dropped into any other Quickshell config.
ShellRoot {
    id: shell

    PanelWindow {
        id: win
        readonly property int cw: 660
        readonly property int ch: 780

        implicitWidth: cw
        implicitHeight: ch
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        // "Keep below": sit under normal windows (above the wallpaper). The layer is raised while the bubble is
        // open because only the Top/Overlay layers can take keyboard focus for typing a question.
        WlrLayershell.layer: (Config.pin === "below" && !assistant.bubbleOpen) ? WlrLayer.Bottom : WlrLayer.Top
        WlrLayershell.namespace: "revvy-ai"
        WlrLayershell.keyboardFocus: assistant.wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // Position: centred by default; dragging moves the margins and the spot is remembered (Config.pos).
        // The character is always clamped on-screen so it can't be lost; "Reset position" re-centres it.
        anchors { left: true; top: true }
        property real mx: 0
        property real my: 0
        property bool dragging: false
        readonly property int layerNow: WlrLayershell.layer   // 1=Bottom 2=Top 3=Overlay (for the status IPC)
        readonly property real sw: screen ? screen.width : 1920
        readonly property real sh: screen ? screen.height : 1080
        function clampX(x) { var a = assistant.agentRect; return Math.max(-a.x, Math.min(x, sw - a.x - a.width)) }
        function clampY(y) { var a = assistant.agentRect; return Math.max(-a.y, Math.min(y, sh - a.y - a.height)) }
        function place() {
            var p = Config.pos
            mx = clampX(p ? p.x : (sw - cw) / 2)
            my = clampY(p ? p.y : (sh - ch) / 2)
        }
        Component.onCompleted: place()
        onScreenChanged: if (!dragging) place()
        // The clamp needs the real agent rectangle, which only exists after the first layout pass / theme load.
        Connections { target: assistant; function onAgentRectChanged() { if (!win.dragging) win.place() } }
        Connections { target: Config; function onPosChanged() { if (!win.dragging) win.place() } }
        margins { left: Math.round(mx); top: Math.round(my) }

        // Only the character, bubble and menu catch the pointer; the rest clicks through.
        mask: Region {
            Region { x: assistant.agentRect.x; y: assistant.agentRect.y; width: assistant.agentRect.width; height: assistant.agentRect.height }
            Region { x: assistant.bubbleRect.x; y: assistant.bubbleRect.y; width: assistant.bubbleRect.width; height: assistant.bubbleRect.height }
            Region { x: assistant.menuRect.x; y: assistant.menuRect.y; width: assistant.menuRect.width; height: assistant.menuRect.height }
        }

        Assistant {
            id: assistant
            anchors.fill: parent
            // Request keyboard focus only while the prompt is actually open.
            // This makes a desktop click or another application's activation
            // return focus immediately instead of leaving a hidden widget
            // surface as the active Wayland target.
            readonly property bool wantsKeyboard: bubbleOpen
            onMoveBy: (dx, dy) => { win.dragging = true; win.mx = win.clampX(win.mx + dx); win.my = win.clampY(win.my + dy) }
            onMoveFinished: { win.dragging = false; Config.save("pos", { x: Math.round(win.mx), y: Math.round(win.my) }) }
            onResetPosition: { win.dragging = false; Config.save("pos", null); win.place() }
            onQuit: Qt.quit()
        }
    }

    // Remote control is sent by /usr/local/bin/revvy-ai. Quickshell routes
    // this to the resident shell; the CLI does not create a second window.
    IpcHandler {
        target: "revvy"
        function ask(question: string): void { assistant.ask(question) }
        function say(text: string): void { assistant.say(text) }
        function command(agent: string, prompt: string, animation: string): void {
            assistant.enqueueCommand(agent, prompt, animation)
        }
        function snapshot(path: string): void { assistant.grabToImage(r => r.saveToFile(path)) }   // debug: render to PNG
        function status(): void { console.log("STATUS " + assistant.statusText + " pos=" + Math.round(win.mx) + "," + Math.round(win.my) + " layer=" + win.layerNow + " screen=" + win.sw + "x" + win.sh) }
        function select(kind: string, value: string): void { assistant.applyChoice(kind, value) }   // same as the right-click menu
        function desktop(): void { console.log("DESKTOP available=" + Desktop.available + " backend=" + Desktop.backend + " tools=" + Desktop.toolNames.join(",")) }
        function resetpos(): void { assistant.resetPosition() }
        function toggle(): void { win.visible = !win.visible }
        function tool(name: string, argsJson: string): void {
            Tools.run(name, JSON.parse(argsJson || "{}"), r => { console.log("TOOL[" + name + "] -> " + r); assistant.say(r.slice(0, 400)) })
        }
    }
}
