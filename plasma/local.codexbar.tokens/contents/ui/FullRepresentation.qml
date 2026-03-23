pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

PlasmaExtras.Representation {
    id: fullRoot

    required property PlasmoidItem rootItem

    collapseMarginsHint: true

    Layout.minimumWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredWidth: Kirigami.Units.gridUnit * 24
    Layout.minimumHeight: contentColumn.implicitHeight + (Kirigami.Units.largeSpacing * 2)

    background: Rectangle {
        radius: Kirigami.Units.largeSpacing * 1.6
        color: Qt.rgba(1, 1, 1, 0.16)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.18)
    }

    contentItem: ColumnLayout {
        id: contentColumn
        spacing: Kirigami.Units.largeSpacing
        anchors.leftMargin: Kirigami.Units.largeSpacing
        anchors.rightMargin: Kirigami.Units.largeSpacing
        anchors.topMargin: Kirigami.Units.largeSpacing
        anchors.bottomMargin: Kirigami.Units.largeSpacing

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: headerLayout.implicitHeight

            RowLayout {
                id: headerLayout
                anchors.fill: parent
                spacing: Kirigami.Units.largeSpacing

                Rectangle {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2.1
                    Layout.preferredHeight: Layout.preferredWidth
                    radius: Kirigami.Units.largeSpacing
                    color: Qt.rgba(1.0, 0.48, 0.33, 0.10)

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
                        text: "Total Tokens"
                        color: Qt.rgba(0.12, 0.1, 0.18, 0.64)
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        font.weight: Font.Medium
                    }

                    Text {
                        text: fullRoot.rootItem.isLoading ? "--" : String(fullRoot.rootItem.snapshot.formattedTotalTokens || "--")
                        color: Qt.rgba(0.12, 0.1, 0.18, 0.98)
                        font.pixelSize: Math.max(28, Kirigami.Theme.defaultFont.pixelSize * 2.4)
                        font.weight: Font.Black
                    }

                    Text {
                        text: fullRoot.rootItem.errorMessage.length > 0
                            ? fullRoot.rootItem.errorMessage
                            : fullRoot.rootItem.relativeTimestamp(fullRoot.rootItem.snapshot.generatedAt)
                        color: fullRoot.rootItem.errorMessage.length > 0
                            ? Qt.rgba(0.67, 0.24, 0.21, 0.92)
                            : Qt.rgba(0.12, 0.1, 0.18, 0.58)
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Qt.rgba(0.2, 0.16, 0.24, 0.08)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Text {
                    text: "Today"
                    color: Qt.rgba(0.12, 0.1, 0.18, 0.62)
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                }

                Text {
                    text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokensToday)
                    color: Qt.rgba(0.12, 0.1, 0.18, 0.92)
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 3
                    font.weight: Font.DemiBold
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Text {
                    text: "7 days"
                    color: Qt.rgba(0.12, 0.1, 0.18, 0.62)
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                }

                Text {
                    text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokens7d)
                    color: Qt.rgba(0.12, 0.1, 0.18, 0.92)
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 3
                    font.weight: Font.DemiBold
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Text {
                    text: "30 days"
                    color: Qt.rgba(0.12, 0.1, 0.18, 0.62)
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                }

                Text {
                    text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokens30d)
                    color: Qt.rgba(0.12, 0.1, 0.18, 0.92)
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 3
                    font.weight: Font.DemiBold
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Qt.rgba(0.2, 0.16, 0.24, 0.08)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Text {
                text: "Sources"
                color: Qt.rgba(0.12, 0.1, 0.18, 0.64)
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                font.weight: Font.Medium
                Layout.bottomMargin: Kirigami.Units.smallSpacing / 2
            }

            Repeater {
                model: fullRoot.rootItem.snapshot.sources || []

                delegate: Item {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing / 2
                    Layout.rightMargin: Kirigami.Units.smallSpacing / 2
                    Layout.topMargin: Kirigami.Units.smallSpacing / 2
                    Layout.bottomMargin: Kirigami.Units.smallSpacing / 2
                    implicitHeight: Math.max(leftColumn.implicitHeight, tokenValue.implicitHeight)

                    Rectangle {
                        width: 7
                        height: 7
                        radius: 3.5
                        x: 0
                        y: Kirigami.Units.smallSpacing * 1.2
                        color: modelData.available ? Qt.rgba(0.23, 0.73, 0.56, 0.96) : Qt.rgba(0.56, 0.54, 0.66, 0.86)
                    }

                    ColumnLayout {
                        id: leftColumn
                        width: parent.width - tokenValue.width - Kirigami.Units.gridUnit * 3
                        x: Kirigami.Units.smallSpacing * 1.8
                        y: 0
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing / 1.5

                        Text {
                            text: modelData.label
                            color: Qt.rgba(0.12, 0.1, 0.18, 0.92)
                            font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 1
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        Text {
                            text: modelData.available && modelData.latestDataAt
                                ? fullRoot.rootItem.relativeTimestamp(modelData.latestDataAt)
                                : fullRoot.rootItem.sourceStatusText(modelData)
                            color: Qt.rgba(0.12, 0.1, 0.18, 0.52)
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            elide: Text.ElideRight
                        }
                    }

                    Text {
                        id: tokenValue
                        text: modelData.formattedTotalTokens
                        color: Qt.rgba(0.12, 0.1, 0.18, 0.86)
                        font.pixelSize: Kirigami.Theme.defaultFont.pixelSize + 1
                        font.weight: Font.DemiBold
                        width: Kirigami.Units.gridUnit * 7.8
                        x: parent.width - width
                        anchors.verticalCenter: leftColumn.verticalCenter
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Qt.rgba(0.2, 0.16, 0.24, 0.08)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Text {
                Layout.fillWidth: true
                text: fullRoot.rootItem.snapshot.unavailableSourceCount > 0
                    ? qsTr("%1 source unavailable").arg(fullRoot.rootItem.snapshot.unavailableSourceCount)
                    : "All sources available"
                color: Qt.rgba(0.12, 0.1, 0.18, 0.56)
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }

            QQC2.Button {
                text: "Refresh"
                onClicked: fullRoot.rootItem.refresh()
            }

            QQC2.Button {
                text: "Settings"
                onClicked: Plasmoid.internalAction("configure").trigger()
            }
        }
    }
}
