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

    // RevolutionWM reports pointer presses outside our layer surface through
    // the existing menu bridge. A serial makes the event reliable even when
    // the desktop click does not activate a regular Wayland window.
    property int inputDismissalSerial: 0

    function setInputOpen(open) {
        revvyInputArmAction.exec(["qdbus", "org.ttos.RevolutionMenu.WaylandBridge",
                                  "/WaylandBridge", "setRevvyAiInputOpen",
                                  open ? "true" : "false"])
    }

    PanelWindow {
        id: win
        readonly property int cw: 660
        readonly property int ch: 780

        implicitWidth: cw
        implicitHeight: ch
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        // Match the other Revolution widgets: display at the Bottom layer so
        // normal applications always paint above Revvy. It is promoted only
        // for the short-lived text-entry state, then immediately returns
        // below the focused application after submit or focus loss.
        WlrLayershell.layer: inputActive ? WlrLayer.Top : WlrLayer.Bottom
        WlrLayershell.namespace: "revvy-ai"
        WlrLayershell.keyboardFocus: assistant.wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // Revvy is deliberately a fixed, centred desktop widget. Keeping the
        // layer surface stationary avoids accidental repositioning and makes
        // its placement identical after every session restart.
        anchors { left: true; top: true }
        readonly property int layerNow: WlrLayershell.layer   // 1=Bottom 2=Top 3=Overlay (for the status IPC)
        readonly property bool inputActive: assistant.inputActive
        readonly property real sw: screen ? screen.width : 1920
        readonly property real sh: screen ? screen.height : 1080
        onInputActiveChanged: shell.setInputOpen(inputActive)
        margins {
            left: Math.max(0, Math.round((win.sw - win.cw) / 2))
            top: Math.max(0, Math.round((win.sh - win.ch) / 2))
        }

        // Only the character, bubble and menu catch the pointer; the rest clicks through.
        mask: Region {
            Region { x: assistant.agentRect.x; y: assistant.agentRect.y; width: assistant.agentRect.width; height: assistant.agentRect.height }
            Region { x: assistant.bubbleRect.x; y: assistant.bubbleRect.y; width: assistant.bubbleRect.width; height: assistant.bubbleRect.height }
        }

        Assistant {
            id: assistant
            anchors.fill: parent
            // Request keyboard focus only while the prompt is actually open.
            // This makes a desktop click or another application's activation
            // return focus immediately instead of leaving a hidden widget
            // surface as the active Wayland target.
            readonly property bool wantsKeyboard: inputActive
            onQuit: Qt.quit()
        }
    }

    Process {
        id: revvyInputArmAction
        stdout: StdioCollector {
            onStreamFinished: {
                const serial = Number(this.text.trim())
                if (isFinite(serial))
                    shell.inputDismissalSerial = serial
            }
        }
    }

    Process {
        id: revvyInputDismissalReader
        command: ["qdbus", "org.ttos.RevolutionMenu.WaylandBridge", "/WaylandBridge",
                  "revvyAiDismissalSerial"]
        stdout: StdioCollector {
            onStreamFinished: {
                const serial = Number(this.text.trim())
                if (!isFinite(serial))
                    return
                if (serial > shell.inputDismissalSerial && win.inputActive)
                    assistant.dismissForFocusLoss()
                if (serial >= shell.inputDismissalSerial)
                    shell.inputDismissalSerial = serial
            }
        }
    }

    Timer {
        // A desktop click does not have to change Wayland's active window.
        // Poll only while text entry is active, mirroring the attached AI
        // drawer's bounded click-away check in the menu.
        interval: 75
        running: win.inputActive
        repeat: true
        onTriggered: {
            if (!revvyInputDismissalReader.running)
                revvyInputDismissalReader.running = true
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
        function status(): void { console.log("STATUS " + assistant.statusText + " pos=center layer=" + win.layerNow + " screen=" + win.sw + "x" + win.sh) }
        function select(kind: string, value: string): void { assistant.applyChoice(kind, value) }
        function desktop(): void { console.log("DESKTOP available=" + Desktop.available + " backend=" + Desktop.backend + " tools=" + Desktop.toolNames.join(",")) }
        function resetpos(): void {} // retained as a harmless compatibility no-op
        function toggle(): void { win.visible = !win.visible }
        function tool(name: string, argsJson: string): void {
            Tools.run(name, JSON.parse(argsJson || "{}"), r => { console.log("TOOL[" + name + "] -> " + r); assistant.say(r.slice(0, 400)) })
        }
    }
}
