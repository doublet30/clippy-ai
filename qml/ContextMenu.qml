import QtQuick

// In-window right-click menu (layer-shell windows can't host native popups).
Rectangle {
    id: root
    property var brains: []        // [{id,label,ready}]
    property var themes: []
    property string brain: ""
    property string theme: ""
    property bool muted: false
    signal choose(string kind, string value)

    visible: false
    width: row.width + 24
    height: row.height + 24
    radius: 8
    color: "#F4F2E4"
    border.color: "#000"
    border.width: 1.5

    function openAt(px, py, parentW, parentH) {
        x = Math.max(4, Math.min(px, parentW - width - 4))
        y = Math.max(4, Math.min(py, parentH - height - 4))
        visible = true
    }

    component Item_ : Rectangle {
        property string label
        property bool active: false
        property bool dim: false
        signal activated()
        width: 170; height: 26; radius: 4
        color: ma.containsMouse ? "#3b78d8" : (active ? "#dcd9bf" : "transparent")
        Text {
            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
            text: (parent.active ? "● " : "   ") + parent.label
            color: ma.containsMouse ? "white" : "#111"
            opacity: parent.dim ? 0.5 : 1
            font.pixelSize: 13
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: parent.activated() }
    }

    Column {
        id: row
        x: 12; y: 12
        spacing: 6
        Row {
            spacing: 14
            Column {
                Text { text: "Brain"; font.bold: true; font.pixelSize: 12; color: "#555" }
                Repeater {
                    model: root.brains
                    Item_ { required property var modelData; label: modelData.label; dim: !modelData.ready
                        active: root.brain === modelData.id; onActivated: { root.choose("provider", modelData.id); root.visible = false } }
                }
            }
            Column {
                Text { text: "Character"; font.bold: true; font.pixelSize: 12; color: "#555" }
                Repeater {
                    model: root.themes
                    Item_ { required property var modelData; label: modelData
                        active: root.theme === modelData; onActivated: { root.choose("theme", modelData); root.visible = false } }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: "#bbb" }
        Row {
            spacing: 14
            Item_ { label: "Animate!"; onActivated: { root.choose("animate", ""); root.visible = false } }
            Item_ { label: root.muted ? "Unmute" : "Mute"; onActivated: { root.choose("mute", ""); root.visible = false } }
        }
        Row {
            spacing: 14
            Item_ { label: "New conversation"; onActivated: { root.choose("reset", ""); root.visible = false } }
            Item_ { label: "Quit"; onActivated: root.choose("quit", "") }
        }
    }
}
