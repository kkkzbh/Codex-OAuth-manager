import QtQuick
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

Kirigami.FormLayout {
    id: page

    property string cfg_bridgePath: Plasmoid.configuration.bridgePath
    property string cfg_collectorPath: Plasmoid.configuration.collectorPath
    property string cfg_codexHomePath: Plasmoid.configuration.codexHomePath
    property int cfg_refreshIntervalSeconds: Plasmoid.configuration.refreshIntervalSeconds
    property int cfg_warnPercent: Plasmoid.configuration.warnPercent
    property int cfg_dangerPercent: Plasmoid.configuration.dangerPercent
    property string cfg_terminalCommand: Plasmoid.configuration.terminalCommand
    property string cfg_loginCommand: Plasmoid.configuration.loginCommand
    property int cfg_liveFetchConcurrency: Plasmoid.configuration.liveFetchConcurrency
    property int cfg_liveFetchTimeoutSeconds: Plasmoid.configuration.liveFetchTimeoutSeconds
    property bool cfg_enableAutoSwitch: Plasmoid.configuration.enableAutoSwitch
    property int cfg_autoSwitch5hThreshold: Plasmoid.configuration.autoSwitch5hThreshold
    property int cfg_autoSwitchWeeklyThreshold: Plasmoid.configuration.autoSwitchWeeklyThreshold
    property string title: i18n("General")

    QQC2.TextField {
        Kirigami.FormData.label: i18n("Bridge path:")
        text: page.cfg_bridgePath
        onTextChanged: page.cfg_bridgePath = text
    }

    QQC2.TextField {
        Kirigami.FormData.label: i18n("Collector path:")
        text: page.cfg_collectorPath
        onTextChanged: page.cfg_collectorPath = text
    }

    QQC2.TextField {
        Kirigami.FormData.label: i18n("Codex home:")
        text: page.cfg_codexHomePath
        onTextChanged: page.cfg_codexHomePath = text
    }

    QQC2.SpinBox {
        Kirigami.FormData.label: i18n("Refresh interval:")
        from: 10
        to: 600
        value: page.cfg_refreshIntervalSeconds
        editable: true
        onValueModified: page.cfg_refreshIntervalSeconds = value
        textFromValue: function(value) { return i18n("%1 seconds", value) }
        valueFromText: function(text) {
            return Number(String(text).replace(/[^0-9]/g, "")) || page.cfg_refreshIntervalSeconds || 120
        }
    }

    QQC2.SpinBox {
        Kirigami.FormData.label: i18n("Warn threshold:")
        from: 1
        to: 100
        value: page.cfg_warnPercent
        editable: true
        onValueModified: page.cfg_warnPercent = value
    }

    QQC2.SpinBox {
        Kirigami.FormData.label: i18n("Danger threshold:")
        from: 1
        to: 100
        value: page.cfg_dangerPercent
        editable: true
        onValueModified: page.cfg_dangerPercent = value
    }

    QQC2.TextField {
        Kirigami.FormData.label: i18n("Terminal command:")
        text: page.cfg_terminalCommand
        onTextChanged: page.cfg_terminalCommand = text
    }

    QQC2.TextField {
        Kirigami.FormData.label: i18n("Login command:")
        text: page.cfg_loginCommand
        onTextChanged: page.cfg_loginCommand = text
    }

    QQC2.SpinBox {
        Kirigami.FormData.label: i18n("Fetch concurrency:")
        from: 1
        to: 16
        value: page.cfg_liveFetchConcurrency
        editable: true
        onValueModified: page.cfg_liveFetchConcurrency = value
    }

    QQC2.SpinBox {
        Kirigami.FormData.label: i18n("Fetch timeout:")
        from: 3
        to: 60
        value: page.cfg_liveFetchTimeoutSeconds
        editable: true
        onValueModified: page.cfg_liveFetchTimeoutSeconds = value
        textFromValue: function(value) { return i18n("%1 seconds", value) }
        valueFromText: function(text) {
            return Number(String(text).replace(/[^0-9]/g, "")) || page.cfg_liveFetchTimeoutSeconds || 12
        }
    }

    QQC2.CheckBox {
        Kirigami.FormData.label: i18n("Enable auto switch:")
        checked: page.cfg_enableAutoSwitch
        onToggled: page.cfg_enableAutoSwitch = checked
    }

    QQC2.SpinBox {
        Kirigami.FormData.label: i18n("Auto-switch 5h threshold:")
        from: 1
        to: 100
        value: page.cfg_autoSwitch5hThreshold
        editable: true
        onValueModified: page.cfg_autoSwitch5hThreshold = value
    }

    QQC2.SpinBox {
        Kirigami.FormData.label: i18n("Auto-switch 1w threshold:")
        from: 1
        to: 100
        value: page.cfg_autoSwitchWeeklyThreshold
        editable: true
        onValueModified: page.cfg_autoSwitchWeeklyThreshold = value
    }
}
