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

    readonly property bool hasError: fullRoot.rootItem.errorMessage.length > 0
    readonly property var sourcesModel: fullRoot.rootItem.snapshot.sources || []
    readonly property string sourceSummary: fullRoot.rootItem.snapshot.unavailableSourceCount > 0
        ? i18n("%1 source unavailable", fullRoot.rootItem.snapshot.unavailableSourceCount)
        : i18n("All sources available")

    collapseMarginsHint: true

    Layout.minimumWidth: Kirigami.Units.gridUnit * 24
    Layout.preferredWidth: Kirigami.Units.gridUnit * 30
    Layout.maximumWidth: Kirigami.Units.gridUnit * 34
    Layout.minimumHeight: Kirigami.Units.gridUnit * 18

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.largeSpacing
        anchors.leftMargin: Kirigami.Units.largeSpacing * 1.2
        anchors.rightMargin: Kirigami.Units.largeSpacing * 1.2
        anchors.topMargin: Kirigami.Units.largeSpacing
        anchors.bottomMargin: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Image {
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                source: "assets/flame.svg"
                sourceSize.width: width
                sourceSize.height: height
                fillMode: Image.PreserveAspectFit
                smooth: true
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing / 2

                PlasmaExtras.Heading {
                    level: 2
                    text: i18n("Codex total tokens")
                    Layout.fillWidth: true
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: fullRoot.hasError
                        ? fullRoot.rootItem.errorMessage
                        : i18n("%1 · %2",
                               fullRoot.rootItem.snapshot.unavailableSourceCount > 0
                                   ? i18n("%1 unavailable", fullRoot.rootItem.snapshot.unavailableSourceCount)
                                   : i18n("%1 online", fullRoot.rootItem.snapshot.availableSourceCount),
                               fullRoot.rootItem.relativeTimestamp(fullRoot.rootItem.snapshot.generatedAt))
                    opacity: fullRoot.hasError ? 0.95 : 0.65
                    color: fullRoot.hasError
                        ? Qt.rgba(0.85, 0.30, 0.24, 1.0)
                        : Kirigami.Theme.textColor
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    elide: Text.ElideRight
                }
            }

            PlasmaComponents3.Label {
                text: fullRoot.rootItem.isLoading
                    ? "--"
                    : String(fullRoot.rootItem.snapshot.formattedTotalTokens || "--")
                opacity: 0.8
                font.weight: Font.DemiBold
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r,
                           Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.10)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaExtras.Heading {
                level: 3
                text: i18n("Totals")
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Kirigami.Units.largeSpacing
                rowSpacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: i18n("All time")
                    opacity: 0.65
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: fullRoot.rootItem.isLoading
                        ? "--"
                        : String(fullRoot.rootItem.snapshot.formattedTotalTokens || "--")
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                }

                PlasmaComponents3.Label {
                    text: i18n("Today")
                    opacity: 0.65
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokensToday)
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                }

                PlasmaComponents3.Label {
                    text: i18n("7 days")
                    opacity: 0.65
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokens7d)
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                }

                PlasmaComponents3.Label {
                    text: i18n("30 days")
                    opacity: 0.65
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.snapshot.tokens30d)
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideLeft
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r,
                           Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.10)
        }

        PlasmaExtras.Heading {
            level: 3
            text: i18n("Sources")
        }

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                model: fullRoot.sourcesModel
                spacing: Kirigami.Units.largeSpacing * 0.6
                clip: true

                delegate: Rectangle {
                    required property var modelData

                    width: ListView.view.width
                    radius: Kirigami.Units.smallSpacing
                    color: modelData.available ? "transparent" : Qt.rgba(0.85, 0.30, 0.24, 0.06)
                    border.width: modelData.available ? 0 : 1
                    border.color: Qt.rgba(0.85, 0.30, 0.24, 0.18)
                    implicitHeight: delegateLayout.implicitHeight + Kirigami.Units.smallSpacing * 2

                    RowLayout {
                        id: delegateLayout
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.largeSpacing * 0.75

                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            width: Kirigami.Units.smallSpacing + 2
                            height: width
                            radius: width / 2
                            color: modelData.available
                                ? Qt.rgba(0.17, 0.67, 0.49, 0.96)
                                : Qt.rgba(0.58, 0.60, 0.66, 0.94)
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing / 2

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: modelData.label
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: modelData.available && modelData.latestDataAt
                                    ? fullRoot.rootItem.relativeTimestamp(modelData.latestDataAt)
                                    : fullRoot.rootItem.sourceStatusText(modelData)
                                opacity: 0.65
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                elide: Text.ElideRight
                            }
                        }

                        PlasmaComponents3.Label {
                            text: modelData.formattedTotalTokens
                            font.weight: Font.DemiBold
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                            elide: Text.ElideLeft
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: fullRoot.rootItem.isLoading
                    ? i18n("Refreshing token totals…")
                    : fullRoot.sourceSummary
                opacity: 0.6
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                elide: Text.ElideRight
            }

            QQC2.Button {
                enabled: !fullRoot.rootItem.isLoading
                text: fullRoot.rootItem.isLoading ? i18n("Refreshing…") : i18n("Refresh")
                icon.name: "view-refresh"
                display: QQC2.AbstractButton.TextBesideIcon
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: i18n("Refresh")
                onClicked: fullRoot.rootItem.refresh()
            }

            QQC2.BusyIndicator {
                visible: fullRoot.rootItem.isLoading
                running: visible
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: Kirigami.Units.iconSizes.small
            }

            QQC2.ToolButton {
                icon.name: "configure"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: i18n("Configure")
                onClicked: Plasmoid.internalAction("configure").trigger()
            }
        }
    }
}
