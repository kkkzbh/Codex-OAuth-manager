pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: compactRoot

    required property PlasmoidItem rootItem

    Layout.minimumWidth: contentRow.implicitWidth + (Kirigami.Units.smallSpacing * 2)
    Layout.minimumHeight: Math.max(contentRow.implicitHeight, Kirigami.Units.gridUnit * 1.4)
    Layout.preferredWidth: Layout.minimumWidth
    Layout.preferredHeight: Layout.minimumHeight
    implicitWidth: Layout.minimumWidth
    implicitHeight: Layout.minimumHeight

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: mouseArea.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"

        Behavior on color {
            ColorAnimation { duration: 140 }
        }
    }

    RowLayout {
        id: contentRow
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.smallSpacing
        anchors.rightMargin: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            source: "codex-app"
        }

        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
            spacing: Math.max(8, Kirigami.Units.smallSpacing * 2)

            UsageBar {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(4, Kirigami.Units.smallSpacing)
                percent: compactRoot.rootItem.currentAccountSessionPercent
                fillColor: compactRoot.rootItem.barColor(percent)
            }

            UsageBar {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(4, Kirigami.Units.smallSpacing)
                percent: compactRoot.rootItem.currentAccountWeeklyPercent
                fillColor: compactRoot.rootItem.barColor(percent)
            }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: function(mouse) {
            if (mouse.button === Qt.MiddleButton) {
                compactRoot.rootItem.refreshAll(true);
                return;
            }
            compactRoot.rootItem.expanded = !compactRoot.rootItem.expanded;
        }
    }
}
