pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

PlasmaExtras.Representation {
    id: fullRoot

    required property PlasmoidItem rootItem

    readonly property color panelColor: Qt.rgba(0.985, 0.985, 0.992, 0.97)
    readonly property color panelBorderColor: Qt.rgba(0.16, 0.18, 0.24, 0.10)
    readonly property color primaryTextColor: Qt.rgba(0.10, 0.12, 0.18, 0.96)
    readonly property color secondaryTextColor: Qt.rgba(0.10, 0.12, 0.18, 0.58)
    readonly property color separatorColor: Qt.rgba(0.10, 0.12, 0.18, 0.08)
    readonly property color accentColor: Qt.rgba(0.19, 0.38, 0.92, 1.0)
    readonly property color accentWashColor: Qt.rgba(0.19, 0.38, 0.92, 0.10)
    readonly property color warmWashColor: Qt.rgba(1.0, 0.48, 0.33, 0.12)
    readonly property bool hasError: fullRoot.rootItem.errorMessage.length > 0

    collapseMarginsHint: true

    implicitWidth: Layout.preferredWidth
    implicitHeight: contentBody.implicitHeight
    Layout.minimumWidth: Kirigami.Units.gridUnit * 22
    Layout.preferredWidth: Kirigami.Units.gridUnit * 26
    Layout.maximumWidth: Kirigami.Units.gridUnit * 30
    Layout.minimumHeight: contentBody.implicitHeight + (Kirigami.Units.largeSpacing * 2.3)
    Layout.preferredHeight: Layout.minimumHeight
    Layout.maximumHeight: Layout.minimumHeight
    Layout.fillHeight: false

    background: Rectangle {
        radius: Kirigami.Units.largeSpacing * 1.7
        color: fullRoot.panelColor
        border.width: 1
        border.color: fullRoot.panelBorderColor
    }

    contentItem: Item {
        id: contentBody
        implicitHeight: contentColumn.implicitHeight + (Kirigami.Units.largeSpacing * 2.3)

        Column {
            id: contentColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Kirigami.Units.largeSpacing * 1.15
            spacing: Kirigami.Units.largeSpacing

            Item {
                width: parent.width
                implicitHeight: headerLayout.implicitHeight

                RowLayout {
                    id: headerLayout
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Kirigami.Units.largeSpacing

                    Rectangle {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.15
                        Layout.preferredHeight: Layout.preferredWidth
                        radius: Kirigami.Units.largeSpacing
                        color: fullRoot.warmWashColor

                        Image {
                            anchors.centerIn: parent
                            source: "assets/flame.svg"
                            width: Kirigami.Units.iconSizes.medium
                            height: Kirigami.Units.iconSizes.medium
                            sourceSize.width: width
                            sourceSize.height: height
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing / 2

                        Text {
                            Layout.fillWidth: true
                            text: i18n("Total Tokens")
                            color: fullRoot.secondaryTextColor
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            text: fullRoot.rootItem.isLoading
                                ? "--"
                                : String(fullRoot.rootItem.snapshot.formattedTotalTokens || "--")
                            color: fullRoot.primaryTextColor
                            font.pixelSize: Math.max(26, Kirigami.Theme.defaultFont.pixelSize * 2.15)
                            minimumPixelSize: Math.max(20, Kirigami.Theme.defaultFont.pixelSize * 1.5)
                            font.weight: Font.Black
                            fontSizeMode: Text.Fit
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            text: fullRoot.hasError
                                ? fullRoot.rootItem.errorMessage
                                : fullRoot.rootItem.relativeTimestamp(fullRoot.rootItem.snapshot.generatedAt)
                            color: fullRoot.hasError
                                ? Qt.rgba(0.74, 0.22, 0.18, 0.92)
                                : fullRoot.secondaryTextColor
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            elide: Text.ElideRight
                        }
                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: Kirigami.Units.smallSpacing / 2
                        visible: !fullRoot.rootItem.isLoading
                        radius: height / 2
                        color: fullRoot.accentWashColor
                        implicitWidth: statusLabel.implicitWidth + Kirigami.Units.largeSpacing
                        implicitHeight: statusLabel.implicitHeight + Kirigami.Units.smallSpacing

                        Text {
                            id: statusLabel
                            anchors.centerIn: parent
                            text: fullRoot.rootItem.snapshot.unavailableSourceCount > 0
                                ? i18n("%1 unavailable", fullRoot.rootItem.snapshot.unavailableSourceCount)
                                : i18n("%1 online", fullRoot.rootItem.snapshot.availableSourceCount)
                            color: fullRoot.accentColor
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            font.weight: Font.DemiBold
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: fullRoot.separatorColor
            }

            Item {
                width: parent.width
                implicitHeight: statsLayout.implicitHeight

                GridLayout {
                    id: statsLayout
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    columns: 2
                    columnSpacing: Kirigami.Units.largeSpacing
                    rowSpacing: Kirigami.Units.smallSpacing

                    Text {
                        text: i18n("Today")
                        color: fullRoot.secondaryTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }

                    Text {
                        Layout.fillWidth: true
                        text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokensToday)
                        color: fullRoot.primaryTextColor
                        font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 3
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideLeft
                    }

                    Text {
                        text: i18n("7 days")
                        color: fullRoot.secondaryTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }

                    Text {
                        Layout.fillWidth: true
                        text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokens7d)
                        color: fullRoot.primaryTextColor
                        font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 3
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideLeft
                    }

                    Text {
                        text: i18n("30 days")
                        color: fullRoot.secondaryTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }

                    Text {
                        Layout.fillWidth: true
                        text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokens30d)
                        color: fullRoot.primaryTextColor
                        font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 3
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideLeft
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: fullRoot.separatorColor
            }

            Item {
                width: parent.width
                implicitHeight: sourcesLayout.implicitHeight

                ColumnLayout {
                    id: sourcesLayout
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Kirigami.Units.largeSpacing * 0.75

                    Text {
                        Layout.fillWidth: true
                        text: i18n("Sources")
                        color: fullRoot.secondaryTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        font.weight: Font.Medium
                    }

                    Repeater {
                        model: fullRoot.rootItem.snapshot.sources || []

                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.largeSpacing * 0.8

                            Rectangle {
                                Layout.alignment: Qt.AlignTop
                                Layout.topMargin: Kirigami.Units.smallSpacing
                                width: 7
                                height: 7
                                radius: 3.5
                                color: modelData.available
                                    ? Qt.rgba(0.17, 0.67, 0.49, 0.96)
                                    : Qt.rgba(0.58, 0.60, 0.66, 0.94)
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.label
                                    color: fullRoot.primaryTextColor
                                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 1
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.available && modelData.latestDataAt
                                        ? fullRoot.rootItem.relativeTimestamp(modelData.latestDataAt)
                                        : fullRoot.rootItem.sourceStatusText(modelData)
                                    color: fullRoot.secondaryTextColor
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                text: modelData.formattedTotalTokens
                                color: fullRoot.primaryTextColor
                                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 1
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideLeft
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: fullRoot.separatorColor
            }

            Item {
                width: parent.width
                implicitHeight: footerLayout.implicitHeight

                RowLayout {
                    id: footerLayout
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Kirigami.Units.smallSpacing

                    Text {
                        Layout.fillWidth: true
                        text: fullRoot.rootItem.snapshot.unavailableSourceCount > 0
                            ? i18n("%1 source unavailable", fullRoot.rootItem.snapshot.unavailableSourceCount)
                            : i18n("All sources available")
                        color: fullRoot.secondaryTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        elide: Text.ElideRight
                    }

                    QQC2.ToolButton {
                        icon.name: "view-refresh"
                        text: i18n("Refresh")
                        display: QQC2.AbstractButton.IconOnly
                        onClicked: fullRoot.rootItem.refresh()
                    }

                    QQC2.ToolButton {
                        icon.name: "settings-configure"
                        text: i18n("Settings")
                        display: QQC2.AbstractButton.IconOnly
                        onClicked: Plasmoid.internalAction("configure").trigger()
                    }
                }
            }
        }
    }
}
