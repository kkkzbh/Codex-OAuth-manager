import QtQuick
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Kirigami.FormLayout {
    id: page

    property string cfg_bridgePath: Plasmoid.configuration.bridgePath
    property int cfg_pollIntervalMs: Plasmoid.configuration.pollIntervalMs
    property int cfg_basePeriodMs: Plasmoid.configuration.basePeriodMs
    property string title: i18n("General")

    QQC2.TextField {
        id: bridgePath
        Kirigami.FormData.label: i18n("Bridge script:")
        text: page.cfg_bridgePath
        placeholderText: "~/.local/bin/codexbar-workers-bridge"
        onTextChanged: page.cfg_bridgePath = text
    }

    QQC2.SpinBox {
        id: pollInterval
        Kirigami.FormData.label: i18n("Poll interval:")
        from: 500
        to: 60000
        stepSize: 500
        value: page.cfg_pollIntervalMs
        editable: true
        onValueModified: page.cfg_pollIntervalMs = value
        textFromValue: function(value) {
            return i18n("%1 ms", value)
        }
        valueFromText: function(text) {
            return Number(String(text).replace(/[^0-9]/g, "")) || 2000
        }
    }

    QQC2.SpinBox {
        id: basePeriod
        Kirigami.FormData.label: i18n("Spin base period:")
        from: 300
        to: 10000
        stepSize: 100
        value: page.cfg_basePeriodMs
        editable: true
        onValueModified: page.cfg_basePeriodMs = value
        textFromValue: function(value) {
            return i18n("%1 ms", value)
        }
        valueFromText: function(text) {
            return Number(String(text).replace(/[^0-9]/g, "")) || 2000
        }
    }
}
