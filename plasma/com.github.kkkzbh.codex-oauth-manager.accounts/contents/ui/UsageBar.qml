import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: bar

    property real percent: 0
    property color trackColor: Qt.rgba(Kirigami.Theme.textColor.r,
                                       Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b,
                                       0.18)
    property color fillColor: Kirigami.Theme.highlightColor

    implicitHeight: Math.max(5, Kirigami.Units.smallSpacing * 1.25)
    implicitWidth: Kirigami.Units.gridUnit * 4

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: bar.trackColor
        antialiasing: true
    }

    Rectangle {
        height: parent.height
        width: parent.width * Math.max(0, Math.min(1, bar.percent / 100))
        radius: height / 2
        color: bar.fillColor
        antialiasing: true

        Behavior on width {
            NumberAnimation { duration: 320; easing.type: Easing.Linear }
        }
        Behavior on color {
            ColorAnimation { duration: 200 }
        }
    }
}
