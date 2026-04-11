pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

QQC2.Control {
    id: fullRoot

    required property PlasmoidItem rootItem

    // Column widths shared by the "Current account" block and the per-account
    // delegate so everything lines up in a strict grid.
    readonly property real identityColumnWidth: Kirigami.Units.gridUnit * 11
    readonly property real meterLabelWidth: Kirigami.Units.gridUnit * 2
    readonly property real meterValueWidth: Kirigami.Units.gridUnit * 7.5
    readonly property real actionsColumnWidth: Kirigami.Units.gridUnit * 11.5
    readonly property real accountRowSpacing: Kirigami.Units.smallSpacing
    readonly property real accountRowEstimatedHeight: Kirigami.Units.gridUnit * 3.6

    readonly property int maxVisibleAccountRows: 8
    readonly property int accountCount: (fullRoot.rootItem.snapshot.accounts || []).length
    readonly property int visibleAccountRowCount: Math.min(accountCount, maxVisibleAccountRows)

    leftPadding: Kirigami.Units.largeSpacing * 1.2
    rightPadding: Kirigami.Units.largeSpacing * 1.2
    topPadding: Kirigami.Units.largeSpacing
    bottomPadding: Kirigami.Units.largeSpacing

    // Propagate sizing from the contentItem (systemmonitor pattern). This is
    // what actually drives the popup window height — the Plasma popup reads
    // Layout.preferredHeight on the full representation.
    //
    // We also pin min == preferred == max on both axes. Plasma only exposes
    // the Alt+drag resize handles (and persists popupWidth/popupHeight) when
    // min < max, so collapsing them locks the popup to our computed size and
    // prevents the user from accidentally shrinking it.
    readonly property real _popupWidth: Kirigami.Units.gridUnit * 36
        + leftPadding + rightPadding
    readonly property real _popupHeight: (contentItem ? contentItem.implicitHeight : 0)
        + topPadding + bottomPadding

    Layout.minimumWidth: _popupWidth
    Layout.preferredWidth: _popupWidth
    Layout.maximumWidth: _popupWidth
    Layout.minimumHeight: _popupHeight
    Layout.preferredHeight: _popupHeight
    Layout.maximumHeight: _popupHeight

    contentItem: ColumnLayout {
        id: contentLayout

        spacing: Kirigami.Units.largeSpacing

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
                    elide: Text.ElideRight
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
                text: fullRoot.rootItem.currentAccount
                    ? fullRoot.rootItem.displayName(fullRoot.rootItem.currentAccount)
                    : ""
                opacity: 0.75
                font.weight: Font.DemiBold
                Layout.alignment: Qt.AlignVCenter
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
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
                spacing: Kirigami.Units.largeSpacing * 0.75

                ColumnLayout {
                    Layout.preferredWidth: fullRoot.identityColumnWidth
                    Layout.maximumWidth: fullRoot.identityColumnWidth
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Kirigami.Units.smallSpacing / 2

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: fullRoot.rootItem.currentAccount
                            ? fullRoot.rootItem.currentAccount.plan
                            : ""
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: fullRoot.rootItem.accountSecondaryText(fullRoot.rootItem.currentAccount, false)
                        opacity: 0.72
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        elide: Text.ElideRight
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Kirigami.Units.smallSpacing / 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents3.Label {
                            text: i18n("5h")
                            Layout.preferredWidth: fullRoot.meterLabelWidth
                        }
                        UsageBar {
                            Layout.fillWidth: true
                            percent: fullRoot.rootItem.usagePercent(fullRoot.rootItem.currentAccount, "session")
                            fillColor: fullRoot.rootItem.barColor(percent)
                        }
                        PlasmaComponents3.Label {
                            text: fullRoot.rootItem.usageLabel(fullRoot.rootItem.currentAccount, "session")
                            Layout.preferredWidth: fullRoot.meterValueWidth
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        PlasmaComponents3.Label {
                            text: i18n("1w")
                            Layout.preferredWidth: fullRoot.meterLabelWidth
                        }
                        UsageBar {
                            Layout.fillWidth: true
                            percent: fullRoot.rootItem.usagePercent(fullRoot.rootItem.currentAccount, "weekly")
                            fillColor: fullRoot.rootItem.barColor(percent)
                        }
                        PlasmaComponents3.Label {
                            text: fullRoot.rootItem.usageLabel(fullRoot.rootItem.currentAccount, "weekly")
                            Layout.preferredWidth: fullRoot.meterValueWidth
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                    }
                }

                // Spacer aligning with the per-account action column below.
                Item {
                    Layout.preferredWidth: fullRoot.actionsColumnWidth
                    Layout.fillHeight: true
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r,
                           Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.10)
        }

        PlasmaExtras.Heading {
            level: 3
            text: i18n("Accounts")
        }

        // Wrap the ListView in an Item so we can set an explicit implicit
        // height that propagates upward through the ColumnLayout → Control →
        // popup. A ScrollView would swallow the implicit size.
        Item {
            id: accountsViewport
            Layout.fillWidth: true
            Layout.preferredHeight: accountsList.preferredViewportHeight
            implicitHeight: accountsList.preferredViewportHeight
            clip: true

            ListView {
                id: accountsList

                // Viewport height capped at `maxVisibleAccountRows`. Uses the
                // measured contentHeight when available, otherwise falls back
                // to an estimate so the popup sizes correctly on the first
                // frame (before delegates are instantiated).
                readonly property real preferredViewportHeight: {
                    const visible = Math.min(count, fullRoot.maxVisibleAccountRows);
                    if (visible <= 0) {
                        return 0;
                    }
                    if (count > 0 && contentHeight > 0) {
                        if (visible >= count) {
                            return contentHeight;
                        }
                        const rowHeight = (contentHeight - spacing * Math.max(0, count - 1)) / count;
                        return rowHeight * visible + spacing * Math.max(0, visible - 1);
                    }
                    return fullRoot.accountRowEstimatedHeight * visible
                        + spacing * Math.max(0, visible - 1);
                }

                anchors.fill: parent
                model: fullRoot.rootItem.snapshot.accounts || []
                spacing: fullRoot.accountRowSpacing
                clip: true
                reuseItems: true
                boundsBehavior: Flickable.StopAtBounds

                QQC2.ScrollBar.vertical: QQC2.ScrollBar {
                    policy: accountsList.contentHeight > accountsList.height
                        ? QQC2.ScrollBar.AsNeeded
                        : QQC2.ScrollBar.AlwaysOff
                }

                delegate: Rectangle {
                    required property var modelData
                    readonly property bool rowIsCurrent: fullRoot.rootItem.isCurrentAccount(modelData)
                    width: ListView.view.width
                    radius: Kirigami.Units.smallSpacing
                    color: rowIsCurrent ? Qt.rgba(0.2, 0.45, 0.95, 0.08) : "transparent"
                    border.width: rowIsCurrent ? 1 : 0
                    border.color: Qt.rgba(0.2, 0.45, 0.95, 0.25)
                    implicitHeight: delegateLayout.implicitHeight + Kirigami.Units.smallSpacing * 2

                    RowLayout {
                        id: delegateLayout
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.largeSpacing * 0.75

                        ColumnLayout {
                            Layout.preferredWidth: fullRoot.identityColumnWidth
                            Layout.maximumWidth: fullRoot.identityColumnWidth
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Kirigami.Units.smallSpacing / 2

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: fullRoot.rootItem.displayName(modelData)
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: fullRoot.rootItem.accountSecondaryText(modelData, true)
                                opacity: 0.72
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                elide: Text.ElideRight
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Kirigami.Units.smallSpacing / 2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                PlasmaComponents3.Label {
                                    text: i18n("5h")
                                    Layout.preferredWidth: fullRoot.meterLabelWidth
                                }
                                UsageBar {
                                    Layout.fillWidth: true
                                    percent: fullRoot.rootItem.usagePercent(modelData, "session")
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                PlasmaComponents3.Label {
                                    text: fullRoot.rootItem.usageLabel(modelData, "session")
                                    Layout.preferredWidth: fullRoot.meterValueWidth
                                    horizontalAlignment: Text.AlignRight
                                    elide: Text.ElideRight
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                PlasmaComponents3.Label {
                                    text: i18n("1w")
                                    Layout.preferredWidth: fullRoot.meterLabelWidth
                                }
                                UsageBar {
                                    Layout.fillWidth: true
                                    percent: fullRoot.rootItem.usagePercent(modelData, "weekly")
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                PlasmaComponents3.Label {
                                    text: fullRoot.rootItem.usageLabel(modelData, "weekly")
                                    Layout.preferredWidth: fullRoot.meterValueWidth
                                    horizontalAlignment: Text.AlignRight
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        RowLayout {
                            Layout.preferredWidth: fullRoot.actionsColumnWidth
                            Layout.maximumWidth: fullRoot.actionsColumnWidth
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Kirigami.Units.smallSpacing

                            QQC2.Button {
                                Layout.fillWidth: true
                                text: rowIsCurrent ? i18n("Active") : i18n("Switch")
                                enabled: !rowIsCurrent && !fullRoot.rootItem.actionInFlight
                                onClicked: fullRoot.rootItem.activateAccount(modelData.accountKey)
                            }

                            QQC2.ToolButton {
                                enabled: !fullRoot.rootItem.actionInFlight
                                icon.name: "view-refresh"
                                display: QQC2.AbstractButton.IconOnly
                                QQC2.ToolTip.visible: hovered
                                QQC2.ToolTip.text: i18n("Refresh this account")
                                onClicked: fullRoot.rootItem.refreshAccount(modelData.accountKey)
                            }

                            // Kept in layout (not `visible: false`) so the
                            // Switch/Active button has the same width on
                            // every row. Sends a tiny Responses-API request
                            // as that account so OpenAI starts its 5h
                            // rate-limit window without the user having to
                            // switch to it first.
                            QQC2.ToolButton {
                                opacity: rowIsCurrent ? 0 : 1
                                enabled: !rowIsCurrent && !fullRoot.rootItem.actionInFlight
                                icon.name: "media-playback-start"
                                display: QQC2.AbstractButton.IconOnly
                                QQC2.ToolTip.visible: hovered && !rowIsCurrent
                                QQC2.ToolTip.text: i18n("Start 5h window (send a tiny request)")
                                onClicked: {
                                    if (!rowIsCurrent) {
                                        fullRoot.rootItem.warmupAccount(modelData.accountKey);
                                    }
                                }
                            }

                            // Kept in layout (not `visible: false`) so the
                            // Switch/Active button has the same width on
                            // every row.
                            QQC2.ToolButton {
                                opacity: rowIsCurrent ? 0 : 1
                                enabled: !rowIsCurrent && !fullRoot.rootItem.actionInFlight
                                icon.name: "edit-delete"
                                display: QQC2.AbstractButton.IconOnly
                                QQC2.ToolTip.visible: hovered && !rowIsCurrent
                                QQC2.ToolTip.text: i18n("Delete account")
                                onClicked: {
                                    if (!rowIsCurrent) {
                                        fullRoot.rootItem.removeAccount(modelData.accountKey);
                                    }
                                }
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
                text: fullRoot.rootItem.footerStatusText()
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
