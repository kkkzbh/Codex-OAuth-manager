import QtQuick
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Kirigami.FormLayout {
    id: page

    property string cfg_collectorPath: Plasmoid.configuration.collectorPath
    property string cfg_collectorPathDefault: "~/.local/bin/codexbar-collector"
    property int cfg_refreshIntervalSeconds: Plasmoid.configuration.refreshIntervalSeconds
    property int cfg_refreshIntervalSecondsDefault: 3
    property bool cfg_expanding: false
    property int cfg_length: 0
    property string title: i18n("General")

    QQC2.TextField {
        id: collectorPath
        Kirigami.FormData.label: i18n("Collector path:")
        text: page.cfg_collectorPath
        placeholderText: "~/.local/bin/codexbar-collector"
        onTextChanged: page.cfg_collectorPath = text
    }

    QQC2.SpinBox {
        id: refreshInterval
        Kirigami.FormData.label: i18n("Refresh interval:")
        from: 3
        to: 300
        stepSize: 1
        value: page.cfg_refreshIntervalSeconds
        editable: true
        onValueModified: page.cfg_refreshIntervalSeconds = value
        textFromValue: function(value) {
            return i18n("%1 seconds", value)
        }
        valueFromText: function(text) {
            return Number(String(text).replace(/[^0-9]/g, "")) || 3
        }
    }
}
