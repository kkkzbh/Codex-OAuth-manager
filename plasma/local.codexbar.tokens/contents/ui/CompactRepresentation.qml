pragma ComponentBehavior: Bound

import QtQuick
import Qt5Compat.GraphicalEffects
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: compactRoot

    required property PlasmoidItem rootItem
    readonly property string targetValue: compactRoot.rootItem.isLoading ? "--" : String(compactRoot.rootItem.snapshot.formattedTotalTokens || "--")
    readonly property color baseWindowTextColor: windowThemeProbe.Kirigami.Theme.textColor
    readonly property color baseViewBackgroundColor: viewThemeProbe.Kirigami.Theme.backgroundColor
    readonly property color displayTextColor: Qt.hsla(baseWindowTextColor.hslHue, baseWindowTextColor.hslSaturation, 0.9, 1)
    readonly property color shadowTextColor: Qt.hsla(baseViewBackgroundColor.hslHue, baseViewBackgroundColor.hslSaturation, baseViewBackgroundColor.hslLightness, 1)

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

    Item {
        id: shadowLayer
        anchors.fill: parent

        DropShadow {
            anchors.fill: contentRow
            cached: true
            source: contentRow
            transparentBorder: true
            horizontalOffset: 0
            verticalOffset: 0
            radius: 5
            samples: 11
            spread: 0.35
            color: compactRoot.shadowTextColor
        }

        RowLayout {
            id: contentRow
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Image {
                source: "assets/flame.svg"
                sourceSize.width: Kirigami.Units.iconSizes.smallMedium
                sourceSize.height: Kirigami.Units.iconSizes.smallMedium
                Layout.alignment: Qt.AlignVCenter
                smooth: true
            }

            Item {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: rollingNumber.implicitWidth
                implicitHeight: rollingNumber.implicitHeight

                RollingNumber {
                    id: rollingNumber
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    valueText: compactRoot.targetValue
                    textColor: compactRoot.displayTextColor
                    fontPixelSize: Math.max(12, Kirigami.Theme.defaultFont.pixelSize + 2)
                    fontWeight: Font.DemiBold
                    fontFamily: Kirigami.Theme.defaultFont.family
                }
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: "Tokens"
                color: compactRoot.displayTextColor
                renderType: Text.QtRendering
                font.pixelSize: Math.max(10, Kirigami.Theme.smallFont.pixelSize)
                font.weight: Font.Medium
                visible: width > 0
            }
        }
    }

    Item {
        id: windowThemeProbe
        visible: false
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
    }

    Item {
        id: viewThemeProbe
        visible: false
        Kirigami.Theme.colorSet: Kirigami.Theme.View
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: compactRoot.rootItem.expanded = !compactRoot.rootItem.expanded
    }
}
