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

    Layout.minimumWidth: Kirigami.Units.gridUnit * 24
    Layout.preferredWidth: Kirigami.Units.gridUnit * 30
    Layout.maximumWidth: Kirigami.Units.gridUnit * 34
    Layout.minimumHeight: Kirigami.Units.gridUnit * 22

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.largeSpacing
        anchors.leftMargin: Kirigami.Units.largeSpacing * 1.2
        anchors.rightMargin: Kirigami.Units.largeSpacing * 1.2
        anchors.topMargin: Kirigami.Units.largeSpacing
        anchors.bottomMargin: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                source: "codex-app"
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing / 2

                PlasmaExtras.Heading {
                    level: 2
                    text: i18n("Codex account limits")
                    Layout.fillWidth: true
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: fullRoot.rootItem.errorMessage.length > 0
                        ? fullRoot.rootItem.errorMessage
                        : fullRoot.rootItem.currentAccountSubtitle()
                    opacity: fullRoot.rootItem.errorMessage.length > 0 ? 0.95 : 0.65
                    color: fullRoot.rootItem.errorMessage.length > 0
                        ? Qt.rgba(0.85, 0.30, 0.24, 1.0)
                        : Kirigami.Theme.textColor
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    elide: Text.ElideRight
                }
            }

            PlasmaComponents3.Label {
                text: fullRoot.rootItem.currentAccount ? fullRoot.rootItem.displayName(fullRoot.rootItem.currentAccount) : ""
                opacity: 0.75
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
            visible: fullRoot.rootItem.currentAccount !== null

            PlasmaExtras.Heading {
                level: 3
                text: i18n("Current account")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                ColumnLayout {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                    PlasmaComponents3.Label {
                        text: fullRoot.rootItem.currentAccount ? fullRoot.rootItem.currentAccount.plan : ""
                        font.weight: Font.DemiBold
                    }
                    PlasmaComponents3.Label {
                        text: fullRoot.rootItem.currentAccount && fullRoot.rootItem.currentAccount.usageSource === "live"
                            ? i18n("Live")
                            : i18n("Cached")
                        opacity: 0.6
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Label {
                            text: i18n("5h")
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                        }
                        UsageBar {
                            Layout.fillWidth: true
                            percent: fullRoot.rootItem.currentAccountSessionPercent
                            fillColor: fullRoot.rootItem.barColor(percent)
                        }
                        PlasmaComponents3.Label {
                            text: fullRoot.rootItem.currentAccountSessionLabel
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents3.Label {
                            text: i18n("1w")
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                        }
                        UsageBar {
                            Layout.fillWidth: true
                            percent: fullRoot.rootItem.currentAccountWeeklyPercent
                            fillColor: fullRoot.rootItem.barColor(percent)
                        }
                        PlasmaComponents3.Label {
                            text: fullRoot.rootItem.currentAccountWeeklyLabel
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                            horizontalAlignment: Text.AlignRight
                        }
                    }
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
            text: i18n("Accounts")
        }

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                model: fullRoot.rootItem.snapshot.accounts || []
                spacing: Kirigami.Units.largeSpacing * 0.6
                clip: true

                delegate: Rectangle {
                    required property var modelData
                    width: ListView.view.width
                    radius: Kirigami.Units.smallSpacing
                    color: modelData.isActive ? Qt.rgba(0.2, 0.45, 0.95, 0.08) : "transparent"
                    border.width: modelData.isActive ? 1 : 0
                    border.color: Qt.rgba(0.2, 0.45, 0.95, 0.25)
                    implicitHeight: delegateLayout.implicitHeight + Kirigami.Units.smallSpacing * 2

                    RowLayout {
                        id: delegateLayout
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.largeSpacing * 0.75

                        ColumnLayout {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 8

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: fullRoot.rootItem.displayName(modelData)
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: modelData.plan + " · " + (modelData.usageSource === "live" ? i18n("Live") : i18n("Cached"))
                                opacity: 0.65
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                elide: Text.ElideRight
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing / 2

                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents3.Label {
                                    text: i18n("5h")
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                                }
                                UsageBar {
                                    Layout.fillWidth: true
                                    percent: modelData.session ? modelData.session.usedPercent : 0
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                PlasmaComponents3.Label {
                                    text: modelData.session ? i18n("%1% · %2", modelData.session.usedPercent, modelData.session.resetsInLabel) : "--"
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    horizontalAlignment: Text.AlignRight
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents3.Label {
                                    text: i18n("1w")
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                                }
                                UsageBar {
                                    Layout.fillWidth: true
                                    percent: modelData.weekly ? modelData.weekly.usedPercent : 0
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                PlasmaComponents3.Label {
                                    text: modelData.weekly ? i18n("%1% · %2", modelData.weekly.usedPercent, modelData.weekly.resetsInLabel) : "--"
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    horizontalAlignment: Text.AlignRight
                                }
                            }
                        }

                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            QQC2.Button {
                                text: modelData.isActive ? i18n("Active") : i18n("Switch")
                                enabled: !modelData.isActive && !fullRoot.rootItem.actionInFlight
                                onClicked: fullRoot.rootItem.activateAccount(modelData.accountKey)
                            }

                            QQC2.ToolButton {
                                visible: !modelData.isActive
                                enabled: !fullRoot.rootItem.actionInFlight
                                icon.name: "edit-delete"
                                display: QQC2.AbstractButton.IconOnly
                                QQC2.ToolTip.visible: hovered
                                QQC2.ToolTip.text: i18n("Delete account")
                                onClicked: fullRoot.rootItem.removeAccount(modelData.accountKey)
                            }
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
                text: fullRoot.rootItem.actionInFlight
                    ? i18n("Refreshing all account limits…")
                    : fullRoot.rootItem.snapshot.status === "stale"
                    ? i18n("Some accounts are using cached data")
                    : i18n("Updated %1", fullRoot.rootItem.relativeTimestamp(fullRoot.rootItem.snapshot.generatedAt))
                opacity: 0.6
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                elide: Text.ElideRight
            }

            QQC2.Button {
                enabled: !fullRoot.rootItem.actionInFlight
                text: fullRoot.rootItem.actionInFlight ? i18n("Refreshing…") : i18n("Refresh all")
                icon.name: "view-refresh"
                display: QQC2.AbstractButton.TextBesideIcon
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: i18n("Refresh all")
                onClicked: fullRoot.rootItem.refreshAll(true)
            }

            QQC2.BusyIndicator {
                visible: fullRoot.rootItem.actionInFlight
                running: visible
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: Kirigami.Units.iconSizes.small
            }

            QQC2.ToolButton {
                icon.name: "list-add"
                display: QQC2.AbstractButton.IconOnly
                enabled: !fullRoot.rootItem.actionInFlight
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: i18n("Add account")
                onClicked: fullRoot.rootItem.addAccount()
            }

            QQC2.ToolButton {
                icon.name: "configure"
                display: QQC2.AbstractButton.IconOnly
                enabled: !fullRoot.rootItem.actionInFlight
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: i18n("Configure")
                onClicked: Plasmoid.internalAction("configure").trigger()
            }
        }
    }
}
