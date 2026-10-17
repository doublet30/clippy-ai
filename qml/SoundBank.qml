import QtQuick
import QtMultimedia

// Plays per-frame sound effects (mp3) shipped with a theme: <themeDir>/sounds/<n>.mp3
Item {
    id: root
    property string dir
    property var names: []
    property bool muted: false
    property real volume: 0.6

    function play(name) {
        if (muted) return
        for (var i = 0; i < rep.count; i++) {
            var it = rep.itemAt(i)
            if (it && it.sname === name) { it.player.stop(); it.player.play(); return }
        }
    }

    Repeater {
        id: rep
        model: root.names
        Item {
            required property var modelData
            property string sname: modelData
            property alias player: mp
            MediaPlayer {
                id: mp
                source: "file://" + root.dir + "/sounds/" + modelData + ".mp3"
                audioOutput: AudioOutput { volume: root.volume }
            }
        }
    }
}
