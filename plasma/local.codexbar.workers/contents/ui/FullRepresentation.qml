pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Item {
    id: fullRoot

    required property PlasmoidItem rootItem

    Layout.preferredWidth: Kirigami.Units.gridUnit * 18
    Layout.preferredHeight: Kirigami.Units.gridUnit * 10
    implicitWidth: Layout.preferredWidth
    implicitHeight: Layout.preferredHeight

    function formatTime(d) {
        if (!d) return fullRoot.rootItem.errorMessage ? "—" : "—";
        const hh = String(d.getHours()).padStart(2, "0");
        const mm = String(d.getMinutes()).padStart(2, "0");
        const ss = String(d.getSeconds()).padStart(2, "0");
        return hh + ":" + mm + ":" + ss;
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            text: i18n("Codex Workers")
            level: 2
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                text: i18n("Active workers:")
                Layout.fillWidth: true
            }
            QQC2.Label {
                text: String(fullRoot.rootItem.workerCount)
                font.bold: true
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                text: i18n("Codex app:")
                Layout.fillWidth: true
            }
            QQC2.Label {
                text: fullRoot.rootItem.appRunning ? i18n("running") : i18n("stopped")
                color: fullRoot.rootItem.appRunning ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: fullRoot.rootItem.mainPid > 0

            QQC2.Label {
                text: i18n("Main PID:")
                Layout.fillWidth: true
            }
            QQC2.Label {
                text: String(fullRoot.rootItem.mainPid)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                text: i18n("Last update:")
                Layout.fillWidth: true
            }
            QQC2.Label {
                text: fullRoot.formatTime(fullRoot.rootItem.lastUpdate)
            }
        }

        QQC2.Label {
            visible: fullRoot.rootItem.errorMessage.length > 0
            text: fullRoot.rootItem.errorMessage
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true

            Item { Layout.fillWidth: true }

            QQC2.Button {
                text: i18n("Refresh now")
                icon.name: "view-refresh"
                onClicked: fullRoot.rootItem.refresh()
            }
        }
    }
}
