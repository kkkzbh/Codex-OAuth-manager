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
    readonly property real meterValueWidth: Kirigami.Units.gridUnit * 5.8
    readonly property real meterPercentWidth: Kirigami.Units.gridUnit * 2.4
    readonly property real meterValueSpacing: Kirigami.Units.smallSpacing / 2
    readonly property real meterResetWidth: meterValueWidth - meterPercentWidth - meterValueSpacing
    readonly property real accountActionsColumnWidth: Kirigami.Units.gridUnit * 11.2
    readonly property real currentActionsColumnWidth: accountActionsColumnWidth
    readonly property real currentActionIconGap: Kirigami.Units.smallSpacing * 2
    readonly property real currentActionFlexibleGapMinimum: Kirigami.Units.largeSpacing
    readonly property real currentAccountPanelSpacing: Kirigami.Units.smallSpacing * 1.2
    readonly property real accountRowSpacing: Kirigami.Units.smallSpacing
    readonly property real accountRowEstimatedHeight: Kirigami.Units.gridUnit * 3.6
    readonly property real resetCreditRowHeight: Kirigami.Units.gridUnit * 2.45
    readonly property int resetCreditsDrawerDuration: Kirigami.Units.shortDuration

    readonly property int maxVisibleAccountRows: 8
    readonly property int maxVisibleResetRows: 4
    readonly property int accountCount: fullRoot.rootItem.otherAccounts.length
    readonly property int visibleAccountRowCount: Math.min(accountCount, maxVisibleAccountRows)
    readonly property string currentAccountKey: fullRoot.rootItem.accountKey(fullRoot.rootItem.currentAccount)

    property bool resetCreditsExpanded: false
    property bool resetCreditsDrawerPresent: false
    property real resetCreditsDrawerHeight: 0
    property real resetCreditsRevealProgress: 0

    function stopResetCreditsDrawerAnimations() {
        resetCreditsOpenRevealAnimation.stop();
        resetCreditsCloseAnimation.stop();
    }

    function showResetCreditsDrawer() {
        stopResetCreditsDrawerAnimations();
        const wasHidden = !resetCreditsDrawerPresent;
        resetCreditsDrawerPresent = true;
        resetCreditsExpanded = true;
        if (wasHidden) {
            resetCreditsRevealProgress = 0;
        }
        resetCreditsDrawerHeight = resetCreditsSection.targetHeight;
        resetCreditsOpenRevealAnimation.restart();
    }

    function hideResetCreditsDrawer() {
        if (!resetCreditsDrawerPresent) {
            return;
        }
        stopResetCreditsDrawerAnimations();
        resetCreditsExpanded = false;
        resetCreditsCloseAnimation.restart();
    }

    function resetResetCreditsDrawer() {
        stopResetCreditsDrawerAnimations();
        resetCreditsExpanded = false;
        resetCreditsDrawerPresent = false;
        resetCreditsDrawerHeight = 0;
        resetCreditsRevealProgress = 0;
    }

    onCurrentAccountKeyChanged: {
        if (resetCreditsDrawerPresent) {
            resetResetCreditsDrawer();
        }
    }

    NumberAnimation {
        id: resetCreditsOpenRevealAnimation

        target: fullRoot
        property: "resetCreditsRevealProgress"
        to: 1
        duration: fullRoot.resetCreditsDrawerDuration
        easing.type: Easing.OutQuad
    }

    SequentialAnimation {
        id: resetCreditsCloseAnimation

        NumberAnimation {
            target: fullRoot
            property: "resetCreditsRevealProgress"
            to: 0
            duration: fullRoot.resetCreditsDrawerDuration
            easing.type: Easing.InQuad
        }

        ScriptAction {
            script: {
                if (!fullRoot.resetCreditsExpanded) {
                    fullRoot.resetCreditsDrawerPresent = false;
                    fullRoot.resetCreditsDrawerHeight = 0;
                    fullRoot.resetCreditsRevealProgress = 0;
                }
            }
        }
    }

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
    readonly property real _popupWidth: Kirigami.Units.gridUnit * 36 + leftPadding + rightPadding
    readonly property real _popupHeight: (contentItem ? contentItem.implicitHeight : 0) + topPadding + bottomPadding

    Layout.minimumWidth: _popupWidth
    Layout.preferredWidth: _popupWidth
    Layout.maximumWidth: _popupWidth
    Layout.minimumHeight: _popupHeight
    Layout.preferredHeight: _popupHeight
    Layout.maximumHeight: _popupHeight

    Connections {
        target: fullRoot.rootItem

        function onExpandedChanged() {
            if (!fullRoot.rootItem.expanded && fullRoot.resetCreditsDrawerPresent) {
                fullRoot.resetResetCreditsDrawer();
            }
        }
    }

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
                    text: fullRoot.rootItem.errorMessage.length > 0 ? fullRoot.rootItem.errorMessage : fullRoot.rootItem.currentAccountSubtitle()
                    opacity: fullRoot.rootItem.errorMessage.length > 0 ? 0.95 : 0.65
                    color: fullRoot.rootItem.errorMessage.length > 0 ? Qt.rgba(0.85, 0.30, 0.24, 1.0) : Kirigami.Theme.textColor
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    elide: Text.ElideRight
                }
            }

            PlasmaComponents3.Label {
                text: fullRoot.rootItem.currentAccount ? fullRoot.rootItem.displayName(fullRoot.rootItem.currentAccount) : ""
                opacity: 0.75
                font.weight: Font.DemiBold
                Layout.alignment: Qt.AlignVCenter
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.10)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: fullRoot.rootItem.currentAccount !== null

            PlasmaExtras.Heading {
                level: 3
                text: i18n("Current account")
            }

            Item {
                id: currentAccountPanel

                Layout.fillWidth: true
                implicitHeight: currentAccountPanelLayout.implicitHeight

                ColumnLayout {
                    id: currentAccountPanelLayout

                    anchors.fill: parent
                    spacing: fullRoot.currentAccountPanelSpacing

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
                                text: fullRoot.rootItem.currentAccount ? fullRoot.rootItem.displayName(fullRoot.rootItem.currentAccount) : ""
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: fullRoot.rootItem.accountSecondaryText(fullRoot.rootItem.currentAccount, true)
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
                                    Layout.minimumWidth: fullRoot.meterLabelWidth
                                    Layout.maximumWidth: fullRoot.meterLabelWidth
                                }
                                UsageBar {
                                    Layout.preferredWidth: implicitWidth
                                    Layout.minimumWidth: implicitWidth
                                    Layout.maximumWidth: implicitWidth
                                    percent: fullRoot.rootItem.usagePercent(fullRoot.rootItem.currentAccount, "session")
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                UsageValue {
                                    rootItem: fullRoot.rootItem
                                    account: fullRoot.rootItem.currentAccount
                                    windowName: "session"
                                    percentWidth: fullRoot.meterPercentWidth
                                    valueSpacing: fullRoot.meterValueSpacing
                                    resetWidth: fullRoot.meterResetWidth
                                    Layout.preferredWidth: fullRoot.meterValueWidth
                                    Layout.minimumWidth: fullRoot.meterValueWidth
                                    Layout.maximumWidth: fullRoot.meterValueWidth
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                PlasmaComponents3.Label {
                                    text: i18n("1w")
                                    Layout.preferredWidth: fullRoot.meterLabelWidth
                                    Layout.minimumWidth: fullRoot.meterLabelWidth
                                    Layout.maximumWidth: fullRoot.meterLabelWidth
                                }
                                UsageBar {
                                    Layout.preferredWidth: implicitWidth
                                    Layout.minimumWidth: implicitWidth
                                    Layout.maximumWidth: implicitWidth
                                    percent: fullRoot.rootItem.usagePercent(fullRoot.rootItem.currentAccount, "weekly")
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                UsageValue {
                                    rootItem: fullRoot.rootItem
                                    account: fullRoot.rootItem.currentAccount
                                    windowName: "weekly"
                                    percentWidth: fullRoot.meterPercentWidth
                                    valueSpacing: fullRoot.meterValueSpacing
                                    resetWidth: fullRoot.meterResetWidth
                                    Layout.preferredWidth: fullRoot.meterValueWidth
                                    Layout.minimumWidth: fullRoot.meterValueWidth
                                    Layout.maximumWidth: fullRoot.meterValueWidth
                                }
                            }
                        }

                        Item {
                            id: resetCreditsAnchor

                            implicitWidth: fullRoot.currentActionsColumnWidth
                            Layout.preferredWidth: fullRoot.currentActionsColumnWidth
                            Layout.maximumWidth: fullRoot.currentActionsColumnWidth
                            Layout.fillHeight: true
                            Layout.alignment: Qt.AlignVCenter

                            RowLayout {
                                anchors.fill: parent
                                spacing: 0

                                Item {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: fullRoot.currentActionFlexibleGapMinimum
                                }

                                QQC2.ToolButton {
                                    id: currentRefreshButton

                                    Layout.alignment: Qt.AlignVCenter
                                    enabled: fullRoot.rootItem.currentAccount !== null && !fullRoot.rootItem.actionInFlight
                                    icon.name: "view-refresh"
                                    display: QQC2.AbstractButton.IconOnly
                                    QQC2.ToolTip.visible: hovered
                                    QQC2.ToolTip.text: i18n("Refresh current account")
                                    onClicked: {
                                        const key = fullRoot.rootItem.accountKey(fullRoot.rootItem.currentAccount);
                                        if (key.length > 0) {
                                            fullRoot.rootItem.refreshAccount(key);
                                        }
                                    }
                                }

                                Item {
                                    Layout.preferredWidth: fullRoot.currentActionIconGap
                                    Layout.minimumWidth: fullRoot.currentActionIconGap
                                    Layout.maximumWidth: fullRoot.currentActionIconGap
                                }

                                QQC2.ToolButton {
                                    id: currentWarmupButton

                                    Layout.alignment: Qt.AlignVCenter
                                    enabled: fullRoot.rootItem.currentAccount !== null && !fullRoot.rootItem.actionInFlight
                                    icon.name: "media-playback-start"
                                    display: QQC2.AbstractButton.IconOnly
                                    QQC2.ToolTip.visible: hovered
                                    QQC2.ToolTip.text: i18n("Start 5h window (send a tiny request)")
                                    onClicked: {
                                        const key = fullRoot.rootItem.accountKey(fullRoot.rootItem.currentAccount);
                                        if (key.length > 0) {
                                            fullRoot.rootItem.warmupAccount(key);
                                        }
                                    }
                                }

                                Item {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: fullRoot.currentActionFlexibleGapMinimum
                                }

                                QQC2.Button {
                                    id: resetCreditsButton

                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 5.2
                                    Layout.minimumWidth: Kirigami.Units.gridUnit * 5.2
                                    Layout.maximumWidth: Kirigami.Units.gridUnit * 5.2
                                    enabled: fullRoot.resetCreditsDrawerPresent || (fullRoot.rootItem.currentAccount !== null && !fullRoot.rootItem.actionInFlight)
                                    text: fullRoot.rootItem.resetCreditButtonText(fullRoot.rootItem.currentAccount)
                                    icon.name: "view-calendar"
                                    display: QQC2.AbstractButton.TextBesideIcon
                                    onClicked: {
                                        if (fullRoot.resetCreditsExpanded) {
                                            fullRoot.hideResetCreditsDrawer();
                                            return;
                                        }

                                        const key = fullRoot.rootItem.accountKey(fullRoot.rootItem.currentAccount);
                                        if (key.length === 0) {
                                            return;
                                        }
                                        const shouldQuery = !fullRoot.resetCreditsDrawerPresent;
                                        fullRoot.showResetCreditsDrawer();
                                        if (shouldQuery) {
                                            fullRoot.rootItem.queryResetCredits(key);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        id: resetCreditsSection

                        Layout.fillWidth: true
                        Layout.preferredHeight: fullRoot.resetCreditsDrawerHeight
                        Layout.topMargin: -fullRoot.currentAccountPanelSpacing
                        visible: fullRoot.resetCreditsDrawerPresent
                        implicitHeight: fullRoot.resetCreditsDrawerHeight
                        radius: Kirigami.Units.smallSpacing
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.035)
                        border.width: 1
                        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                        clip: true

                        readonly property real contentMargins: Kirigami.Units.largeSpacing * 0.7
                        readonly property real resetCreditRowSpacing: Kirigami.Units.smallSpacing / 2
                        readonly property int snapshotResetRowCount: {
                            const snapshot = fullRoot.rootItem.currentResetCredits();
                            return snapshot && snapshot.credits ? snapshot.credits.length : -1;
                        }
                        readonly property int advertisedResetRowCount: fullRoot.rootItem.resetCreditCount(fullRoot.rootItem.currentAccount)
                        readonly property int layoutResetRowCount: snapshotResetRowCount >= 0 ? snapshotResetRowCount : (advertisedResetRowCount > 0 ? advertisedResetRowCount : fullRoot.maxVisibleResetRows)
                        readonly property int visibleResetRowCount: Math.max(1, Math.min(fullRoot.maxVisibleResetRows, layoutResetRowCount))
                        readonly property real listBodyHeight: fullRoot.resetCreditRowHeight * visibleResetRowCount + resetCreditRowSpacing * Math.max(0, visibleResetRowCount - 1)
                        readonly property real maxBodyHeight: fullRoot.resetCreditRowHeight * fullRoot.maxVisibleResetRows + resetCreditRowSpacing * Math.max(0, fullRoot.maxVisibleResetRows - 1)
                        readonly property real statusBodyHeight: fullRoot.resetCreditRowHeight
                        readonly property real errorBodyHeight: Math.min(maxBodyHeight, Math.max(statusBodyHeight, resetCreditsErrorText.implicitHeight))
                        readonly property bool hasResetCredits: !fullRoot.rootItem.resetCreditsLoading && fullRoot.rootItem.resetCreditsError.length === 0 && fullRoot.rootItem.currentResetCredits() && fullRoot.rootItem.currentResetCredits().credits && fullRoot.rootItem.currentResetCredits().credits.length > 0
                        readonly property real bodyHeight: {
                            if (fullRoot.rootItem.resetCreditsError.length > 0) {
                                return errorBodyHeight;
                            }
                            if (!fullRoot.rootItem.resetCreditsLoading && !hasResetCredits && snapshotResetRowCount >= 0) {
                                return statusBodyHeight;
                            }
                            return listBodyHeight;
                        }
                        readonly property real targetHeight: contentMargins * 2 + resetCreditsHeader.implicitHeight + resetCreditsDivider.implicitHeight + bodyHeight + resetCreditsSectionLayout.spacing * 2
                        readonly property real contentTravel: Math.max(Kirigami.Units.gridUnit * 2, targetHeight - contentMargins * 2)

                        onTargetHeightChanged: {
                            if (fullRoot.resetCreditsDrawerPresent && fullRoot.resetCreditsExpanded && !resetCreditsCloseAnimation.running) {
                                fullRoot.resetCreditsDrawerHeight = targetHeight;
                            }
                        }

                        Item {
                            id: resetCreditsSectionContent

                            x: resetCreditsSection.contentMargins
                            y: resetCreditsSection.contentMargins - resetCreditsSection.contentTravel * (1 - fullRoot.resetCreditsRevealProgress)
                            width: Math.max(0, resetCreditsSection.width - resetCreditsSection.contentMargins * 2)
                            height: Math.max(0, resetCreditsSection.targetHeight - resetCreditsSection.contentMargins * 2)
                            opacity: fullRoot.resetCreditsRevealProgress

                            ColumnLayout {
                                id: resetCreditsSectionLayout

                                anchors.fill: parent
                                spacing: Kirigami.Units.smallSpacing

                                RowLayout {
                                    id: resetCreditsHeader

                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0

                                        PlasmaComponents3.Label {
                                            Layout.fillWidth: true
                                            text: i18n("Reset expiries")
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                        }

                                        PlasmaComponents3.Label {
                                            Layout.fillWidth: true
                                            text: {
                                                if (fullRoot.rootItem.resetCreditsLoading) {
                                                    return i18n("Checking reset credits…");
                                                }
                                                if (fullRoot.rootItem.resetCreditsError.length > 0) {
                                                    return i18n("Query failed");
                                                }
                                                const snapshot = fullRoot.rootItem.currentResetCredits();
                                                if (!snapshot) {
                                                    return i18n("Live query");
                                                }
                                                if (!snapshot.credits || snapshot.credits.length === 0) {
                                                    return i18n("No reset credits");
                                                }
                                                return snapshot.availableCount === 1 ? i18n("1 available") : i18n("%1 available", snapshot.availableCount);
                                            }
                                            opacity: 0.65
                                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                Rectangle {
                                    id: resetCreditsDivider

                                    Layout.fillWidth: true
                                    implicitHeight: 1
                                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                                }

                                Item {
                                    id: resetCreditsBodySlot

                                    Layout.fillWidth: true
                                    Layout.preferredHeight: resetCreditsSection.bodyHeight
                                    implicitHeight: resetCreditsSection.bodyHeight
                                    clip: true

                                    PlasmaComponents3.Label {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: fullRoot.rootItem.resetCreditsLoading
                                        text: i18n("Checking reset credits…")
                                        opacity: 0.75
                                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                        elide: Text.ElideRight
                                    }

                                    Flickable {
                                        id: resetCreditsErrorScroller

                                        anchors.fill: parent
                                        visible: fullRoot.rootItem.resetCreditsError.length > 0
                                        clip: true
                                        contentWidth: width
                                        contentHeight: resetCreditsErrorText.implicitHeight
                                        boundsBehavior: Flickable.StopAtBounds
                                        interactive: contentHeight > height

                                        QQC2.ScrollBar.vertical: QQC2.ScrollBar {
                                            policy: resetCreditsErrorScroller.contentHeight > resetCreditsErrorScroller.height ? QQC2.ScrollBar.AsNeeded : QQC2.ScrollBar.AlwaysOff
                                        }

                                        PlasmaComponents3.Label {
                                            id: resetCreditsErrorText

                                            width: resetCreditsErrorScroller.width
                                            text: fullRoot.rootItem.resetCreditsError
                                            color: Qt.rgba(0.85, 0.30, 0.24, 1.0)
                                            wrapMode: Text.WordWrap
                                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                        }
                                    }

                                    PlasmaComponents3.Label {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !fullRoot.rootItem.resetCreditsLoading && fullRoot.rootItem.resetCreditsError.length === 0 && !resetCreditsSection.hasResetCredits
                                        text: i18n("No reset credits")
                                        opacity: 0.65
                                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                        elide: Text.ElideRight
                                    }

                                    ListView {
                                        id: resetCreditsList

                                        anchors.fill: parent
                                        visible: resetCreditsSection.hasResetCredits
                                        model: {
                                            const snapshot = fullRoot.rootItem.currentResetCredits();
                                            return snapshot && snapshot.credits ? snapshot.credits : [];
                                        }
                                        spacing: resetCreditsSection.resetCreditRowSpacing
                                        clip: true
                                        reuseItems: true
                                        boundsBehavior: Flickable.StopAtBounds

                                        QQC2.ScrollBar.vertical: QQC2.ScrollBar {
                                            policy: resetCreditsList.contentHeight > resetCreditsList.height ? QQC2.ScrollBar.AsNeeded : QQC2.ScrollBar.AlwaysOff
                                        }

                                        delegate: Item {
                                            id: resetCreditDelegate

                                            required property var modelData
                                            required property int index

                                            readonly property bool creditAvailable: String(resetCreditDelegate.modelData.status || "") === "available"

                                            width: ListView.view.width
                                            height: fullRoot.resetCreditRowHeight
                                            opacity: resetCreditDelegate.creditAvailable ? 1 : 0.65

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: Kirigami.Units.smallSpacing / 2
                                                anchors.rightMargin: Kirigami.Units.smallSpacing
                                                spacing: Kirigami.Units.smallSpacing

                                                Rectangle {
                                                    Layout.preferredWidth: Kirigami.Units.smallSpacing
                                                    Layout.preferredHeight: width
                                                    Layout.alignment: Qt.AlignVCenter
                                                    radius: width / 2
                                                    color: resetCreditDelegate.creditAvailable ? Kirigami.Theme.highlightColor : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.35)
                                                }

                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    Layout.alignment: Qt.AlignVCenter
                                                    spacing: 0

                                                    PlasmaComponents3.Label {
                                                        Layout.fillWidth: true
                                                        text: i18n("Reset %1", resetCreditDelegate.index + 1)
                                                        font.weight: Font.DemiBold
                                                        elide: Text.ElideRight
                                                    }

                                                    PlasmaComponents3.Label {
                                                        Layout.fillWidth: true
                                                        text: fullRoot.rootItem.resetCreditExpiryText(resetCreditDelegate.modelData)
                                                        opacity: 0.65
                                                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                PlasmaComponents3.Label {
                                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 6.2
                                                    Layout.maximumWidth: Kirigami.Units.gridUnit * 6.2
                                                    Layout.alignment: Qt.AlignVCenter
                                                    text: fullRoot.rootItem.resetCreditRemainingText(resetCreditDelegate.modelData)
                                                    color: resetCreditDelegate.creditAvailable ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                                                    font.weight: Font.DemiBold
                                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                                    horizontalAlignment: Text.AlignRight
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            Rectangle {
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.bottom: parent.bottom
                                                height: 1
                                                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.06)
                                                visible: resetCreditDelegate.index < resetCreditsList.count - 1
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents3.Label {
                                text: fullRoot.rootItem.tokenTotalText()
                                font.weight: Font.DemiBold
                                elide: Text.ElideLeft
                            }

                            PlasmaComponents3.Label {
                                text: i18n("tokens")
                                opacity: 0.68
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                elide: Text.ElideRight
                            }
                        }

                        ColumnLayout {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 5.2
                            spacing: 0

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.tokenSnapshot.tokensToday)
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideLeft
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("Today")
                                opacity: 0.65
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        ColumnLayout {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 5.8
                            spacing: 0

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.tokenSnapshot.tokensWeek)
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideLeft
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("This week")
                                opacity: 0.65
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        ColumnLayout {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 6.2
                            spacing: 0

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: fullRoot.rootItem.formatInteger(fullRoot.rootItem.tokenSnapshot.tokensMonth)
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideLeft
                            }
                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                text: i18n("This month")
                                opacity: 0.65
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.10)
        }

        PlasmaExtras.Heading {
            level: 3
            text: i18n("Accounts")
        }

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            visible: fullRoot.rootItem.otherAccounts.length === 0
            text: i18n("No other accounts")
            opacity: 0.65
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            elide: Text.ElideRight
        }

        // Wrap the ListView in an Item so we can set an explicit implicit
        // height that propagates upward through the ColumnLayout → Control →
        // popup. A ScrollView would swallow the implicit size.
        Item {
            id: accountsViewport
            Layout.fillWidth: true
            Layout.preferredHeight: accountsList.preferredViewportHeight
            implicitHeight: accountsList.preferredViewportHeight
            visible: fullRoot.rootItem.otherAccounts.length > 0
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
                    return fullRoot.accountRowEstimatedHeight * visible + spacing * Math.max(0, visible - 1);
                }

                anchors.fill: parent
                model: fullRoot.rootItem.otherAccounts
                spacing: fullRoot.accountRowSpacing
                clip: true
                reuseItems: true
                boundsBehavior: Flickable.StopAtBounds

                QQC2.ScrollBar.vertical: QQC2.ScrollBar {
                    policy: accountsList.contentHeight > accountsList.height ? QQC2.ScrollBar.AsNeeded : QQC2.ScrollBar.AlwaysOff
                }

                delegate: Rectangle {
                    required property var modelData
                    width: ListView.view.width
                    radius: Kirigami.Units.smallSpacing
                    color: "transparent"
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
                                    Layout.minimumWidth: fullRoot.meterLabelWidth
                                    Layout.maximumWidth: fullRoot.meterLabelWidth
                                }
                                UsageBar {
                                    Layout.preferredWidth: implicitWidth
                                    Layout.minimumWidth: implicitWidth
                                    Layout.maximumWidth: implicitWidth
                                    percent: fullRoot.rootItem.usagePercent(modelData, "session")
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                UsageValue {
                                    rootItem: fullRoot.rootItem
                                    account: modelData
                                    windowName: "session"
                                    percentWidth: fullRoot.meterPercentWidth
                                    valueSpacing: fullRoot.meterValueSpacing
                                    resetWidth: fullRoot.meterResetWidth
                                    Layout.preferredWidth: fullRoot.meterValueWidth
                                    Layout.minimumWidth: fullRoot.meterValueWidth
                                    Layout.maximumWidth: fullRoot.meterValueWidth
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                PlasmaComponents3.Label {
                                    text: i18n("1w")
                                    Layout.preferredWidth: fullRoot.meterLabelWidth
                                    Layout.minimumWidth: fullRoot.meterLabelWidth
                                    Layout.maximumWidth: fullRoot.meterLabelWidth
                                }
                                UsageBar {
                                    Layout.preferredWidth: implicitWidth
                                    Layout.minimumWidth: implicitWidth
                                    Layout.maximumWidth: implicitWidth
                                    percent: fullRoot.rootItem.usagePercent(modelData, "weekly")
                                    fillColor: fullRoot.rootItem.barColor(percent)
                                }
                                UsageValue {
                                    rootItem: fullRoot.rootItem
                                    account: modelData
                                    windowName: "weekly"
                                    percentWidth: fullRoot.meterPercentWidth
                                    valueSpacing: fullRoot.meterValueSpacing
                                    resetWidth: fullRoot.meterResetWidth
                                    Layout.preferredWidth: fullRoot.meterValueWidth
                                    Layout.minimumWidth: fullRoot.meterValueWidth
                                    Layout.maximumWidth: fullRoot.meterValueWidth
                                }
                            }
                        }

                        RowLayout {
                            Layout.preferredWidth: fullRoot.accountActionsColumnWidth
                            Layout.maximumWidth: fullRoot.accountActionsColumnWidth
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Kirigami.Units.smallSpacing

                            QQC2.Button {
                                id: switchButton

                                Layout.fillWidth: true
                                text: i18n("Switch")
                                enabled: !fullRoot.rootItem.actionInFlight
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

                            QQC2.ToolButton {
                                enabled: !fullRoot.rootItem.actionInFlight
                                icon.name: "media-playback-start"
                                display: QQC2.AbstractButton.IconOnly
                                QQC2.ToolTip.visible: hovered
                                QQC2.ToolTip.text: i18n("Start 5h window (send a tiny request)")
                                onClicked: fullRoot.rootItem.warmupAccount(modelData.accountKey)
                            }

                            QQC2.ToolButton {
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
                onClicked: fullRoot.rootItem.refreshEverything()
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
