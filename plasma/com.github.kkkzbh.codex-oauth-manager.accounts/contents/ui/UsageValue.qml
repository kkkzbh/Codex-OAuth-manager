pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid

Item {
    id: valueRoot

    required property PlasmoidItem rootItem
    property var account: null
    property string windowName: ""
    property real percentWidth: Kirigami.Units.gridUnit * 2.6
    property real valueSpacing: Kirigami.Units.smallSpacing / 2
    property real resetWidth: Kirigami.Units.gridUnit * 4.1

    readonly property bool hasWindow: rootItem.hasUsageWindow(account, windowName)

    implicitWidth: percentWidth + valueSpacing + resetWidth
    implicitHeight: Math.max(valueRow.implicitHeight, placeholder.implicitHeight)

    RowLayout {
        id: valueRow

        anchors.fill: parent
        spacing: valueRoot.valueSpacing
        visible: valueRoot.hasWindow

        PlasmaComponents3.Label {
            Layout.preferredWidth: valueRoot.percentWidth
            Layout.minimumWidth: valueRoot.percentWidth
            Layout.maximumWidth: valueRoot.percentWidth
            text: valueRoot.rootItem.usagePercentLabel(valueRoot.account, valueRoot.windowName)
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
        }

        PlasmaComponents3.Label {
            Layout.preferredWidth: valueRoot.resetWidth
            Layout.minimumWidth: valueRoot.resetWidth
            Layout.maximumWidth: valueRoot.resetWidth
            text: valueRoot.rootItem.usageResetLabel(valueRoot.account, valueRoot.windowName)
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
        }
    }

    PlasmaComponents3.Label {
        id: placeholder

        anchors.fill: parent
        visible: !valueRoot.hasWindow
        text: "--"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
