import QtQuick
import QtQuick.Shapes

// Speech balloon. Pops open as a small bubble, then widens into the search bar;
// the same bubble becomes the "thinking" dots, the answer text, or a confirm prompt.
Item {
    id: root

    // closed | input | thinking | speak | confirm
    property string mode: "closed"
    property string fullText: ""      // complete message (sizes the bubble)
    property string shownText: ""     // revealed so far ("pasted" in while speaking)
    property string hint: ""
    property color bg: "#FFFFCC"
    property color fg: "#111111"
    property color border: "#000000"
    property string fontFamily: "Tahoma, DejaVu Sans, sans-serif"
    property int fontSize: 15
    readonly property int maxW: 440
    readonly property int tailH: 16
    readonly property bool isOpen: mode !== "closed"

    signal submitted(string text)
    signal confirmed(bool ok)
    signal dismissed()
    signal clicked()

    function focusInput() { field.forceActiveFocus(); field.selectAll() }
    function clearInput() { field.text = "" }

    // Size of the body for the current mode
    readonly property real bodyW: !expanded ? 46
        : mode === "input" ? 400
        : mode === "thinking" ? 92
        : Math.max(150, Math.min(maxW, measure.contentWidth + 36))
    readonly property real bodyH: !expanded ? 36
        : mode === "input" ? 70
        : mode === "thinking" ? 46
        : Math.min(280, measure.contentHeight + 30) + (mode === "confirm" ? 46 : 0)
    property bool expanded: false

    implicitWidth: maxW + 20
    implicitHeight: 280 + tailH + 50

    onModeChanged: {
        if (mode === "closed") { expanded = false; return }
        if (!expanded) { expandTimer.restart() }
        if (mode === "input") Qt.callLater(focusInput)
    }
    Timer { id: expandTimer; interval: 220; onTriggered: root.expanded = true }

    Text {      // invisible measuring twin of the answer text
        id: measure
        visible: false
        width: root.maxW - 36
        text: root.fullText
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        wrapMode: Text.WordWrap
    }

    Item {
        id: holder
        width: body.width
        height: body.height + root.tailH
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        transformOrigin: Item.Bottom
        scale: root.isOpen ? 1 : 0
        opacity: root.isOpen ? 1 : 0
        Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
        Behavior on opacity { NumberAnimation { duration: 140 } }

        Shape {     // tail
            x: body.width / 2 - 12
            y: body.height - 1
            ShapePath {
                strokeColor: root.border; strokeWidth: 1.5; fillColor: root.bg
                startX: 0; startY: 0
                PathLine { x: 6; y: root.tailH }
                PathLine { x: 24; y: 0 }
            }
        }
        Rectangle {
            id: body
            width: root.bodyW
            height: root.bodyH
            radius: 10
            color: root.bg
            border.color: root.border
            border.width: 1.5
            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            Rectangle {   // hides the border where the tail joins
                x: parent.width / 2 - 11; y: parent.height - 2; width: 22; height: 3; color: root.bg
            }

            // ---------- answer text ----------
            Flickable {
                id: flick
                visible: root.mode === "speak" || root.mode === "confirm"
                opacity: root.expanded ? 1 : 0
                x: 18; y: 15
                width: parent.width - 36
                height: Math.min(250, measure.contentHeight)
                contentHeight: answer.implicitHeight
                clip: true
                interactive: contentHeight > height
                Text {
                    id: answer
                    width: flick.width
                    text: root.shownText
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    wrapMode: Text.WordWrap
                    onTextChanged: if (flick.contentHeight > flick.height) flick.contentY = flick.contentHeight - flick.height
                }
            }
            MouseArea {
                anchors.fill: parent
                visible: root.mode === "speak"
                onClicked: root.clicked()
            }

            // ---------- confirm buttons ----------
            Row {
                visible: root.mode === "confirm" && root.expanded
                anchors.bottom: parent.bottom; anchors.bottomMargin: 10
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12
                Repeater {
                    model: [{ t: "Allow", ok: true }, { t: "Deny", ok: false }]
                    Rectangle {
                        required property var modelData
                        width: 84; height: 28; radius: 5
                        color: ma.pressed ? "#c8c8a0" : "#ECE9D8"
                        border.color: root.border
                        Text { anchors.centerIn: parent; text: parent.modelData.t; font.family: root.fontFamily; font.pixelSize: 14; color: "#111" }
                        MouseArea { id: ma; anchors.fill: parent; onClicked: root.confirmed(parent.modelData.ok) }
                    }
                }
            }

            // ---------- thinking dots ----------
            Row {
                visible: root.mode === "thinking" && root.expanded
                anchors.centerIn: parent
                spacing: 8
                Repeater {
                    model: 3
                    Rectangle {
                        required property int index
                        width: 10; height: 10; radius: 5; color: root.fg
                        SequentialAnimation on y {
                            running: root.mode === "thinking" && root.expanded
                            loops: Animation.Infinite
                            PauseAnimation { duration: index * 140 }
                            NumberAnimation { to: -6; duration: 220; easing.type: Easing.OutQuad }
                            NumberAnimation { to: 0; duration: 220; easing.type: Easing.InQuad }
                            PauseAnimation { duration: (2 - index) * 140 }
                        }
                    }
                }
            }

            // ---------- the search bar ----------
            Item {
                id: bar
                visible: root.mode === "input"
                opacity: root.expanded ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 180 } }
                anchors.fill: parent
                anchors.margins: 12

                Rectangle {
                    id: box
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 34; radius: 17
                    color: "white"; border.color: field.activeFocus ? "#3b78d8" : "#8a8a70"; border.width: 1.5
                    TextInput {
                        id: field
                        anchors { left: parent.left; right: send.left; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 6 }
                        color: "#111"
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                        clip: true
                        selectByMouse: true
                        onAccepted: { var t = text.trim(); if (t) root.submitted(t) }
                        Keys.onEscapePressed: root.dismissed()
                        // The widget only owns keyboard focus for an active
                        // prompt.  A click on the desktop or another window
                        // clears this focus on both Wayland and X11; dismiss
                        // the bubble just like the menu's AI drawer does.
                        onActiveFocusChanged: {
                            if (!activeFocus && root.mode === "input")
                                root.dismissed()
                        }
                        Text {
                            visible: !field.text && !field.preeditText
                            text: "Ask me anything…"
                            color: "#999"; font: field.font
                        }
                    }
                    Rectangle {
                        id: send
                        anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                        width: 26; height: 26; radius: 13
                        color: field.text.trim() ? "#3b78d8" : "#c8c8b4"
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text { anchors.centerIn: parent; text: "➤"; color: "white"; font.pixelSize: 12 }
                        MouseArea { anchors.fill: parent; onClicked: field.accepted() }
                    }
                }
                Text {
                    anchors { left: parent.left; leftMargin: 6; bottom: parent.bottom }
                    text: root.hint
                    color: "#777760"; font.family: root.fontFamily; font.pixelSize: 11
                }
            }
        }
    }
}
