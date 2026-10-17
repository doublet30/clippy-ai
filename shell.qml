//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "qml"

// Entry point:  quickshell -p /path/to/clippy-ai
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
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "clippy-ai"
        WlrLayershell.keyboardFocus: assistant.wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // Appears centred on screen; dragging moves the margins.
        anchors { left: true; top: true }
        property real mx: Math.max(0, ((screen ? screen.width : 1920) - cw) / 2)
        property real my: Math.max(0, ((screen ? screen.height : 1080) - ch) / 2)
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
            readonly property bool wantsKeyboard: true
            onMoveBy: (dx, dy) => { win.mx += dx; win.my += dy }
            onQuit: Qt.quit()
        }
    }

    // Remote control:  quickshell -p <dir> ipc call clippy ask "what's the weather?"
    IpcHandler {
        target: "clippy"
        function ask(question: string): void { assistant.ask(question) }
        function say(text: string): void { assistant.say(text) }
        function snapshot(path: string): void { assistant.grabToImage(r => r.saveToFile(path)) }   // debug: render to PNG
        function status(): void { console.log("STATUS " + assistant.statusText) }
        function select(kind: string, value: string): void { assistant.applyChoice(kind, value) }   // same as the right-click menu
        function toggle(): void { win.visible = !win.visible }
        function tool(name: string, argsJson: string): void {
            Tools.run(name, JSON.parse(argsJson || "{}"), r => { console.log("TOOL[" + name + "] -> " + r); assistant.say(r.slice(0, 400)) })
        }
    }
}
