pragma ComponentBehavior: Bound

import QtQuick
import QtCore

import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    readonly property string homePath: normalizePath(StandardPaths.writableLocation(StandardPaths.HomeLocation))
    readonly property string bridgePathExpanded: {
        const configured = Plasmoid.configuration.bridgePath || "~/.local/bin/codexbar-workers-bridge";
        const expanded = configured.startsWith("~") ? homePath + configured.slice(1) : configured;
        return normalizePath(expanded);
    }
    readonly property int pollIntervalMs: Math.max(500, Plasmoid.configuration.pollIntervalMs || 2000)
    readonly property int basePeriodMs: Math.max(300, Plasmoid.configuration.basePeriodMs || 2000)
    readonly property string commandSource: "sh -lc " + shellQuote(bridgePathExpanded)

    property int workerCount: 0
    property bool appRunning: false
    property int mainPid: 0
    property string errorMessage: ""
    property var lastUpdate: null

    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.title: i18n("CodexBar Workers")
    Plasmoid.icon: "view-process-all"
    toolTipMainText: i18n("CodexBar Workers")
    toolTipSubText: {
        if (!root.appRunning) {
            return i18n("Codex app is not running");
        }
        if (root.workerCount === 0) {
            return i18n("Idle — no active workers");
        }
        return i18np("%1 active worker", "%1 active workers", root.workerCount);
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\"'\"'") + "'";
    }

    function normalizePath(value) {
        let normalized = String(value || "").trim();
        if (normalized.startsWith("file://")) {
            normalized = normalized.slice("file://".length);
        }
        return normalized;
    }

    function refresh() {
        executable.connectedSources = [];
        executable.connectedSources = [commandSource];
    }

    function parsePayload(stdout) {
        try {
            const data = JSON.parse(stdout);
            workerCount = Math.max(0, Number(data.count || 0));
            appRunning = Boolean(data.app_running);
            mainPid = Number(data.main_pid || 0);
            errorMessage = data.error ? String(data.error) : "";
            lastUpdate = new Date();
        } catch (error) {
            console.log("[codexbar-workers] invalid payload", stdout);
            errorMessage = i18n("Invalid bridge payload");
        }
    }

    compactRepresentation: CompactRepresentation {
        rootItem: root
    }

    fullRepresentation: FullRepresentation {
        rootItem: root
    }

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        interval: root.pollIntervalMs
        connectedSources: root.commandSource.length > 0 ? [root.commandSource] : []

        onNewData: function(sourceName, data) {
            const exitCode = Number(data["exit code"] ?? data.exitCode ?? 0);
            const stdout = String(data.stdout ?? "");
            const stderr = String(data.stderr ?? "");

            if (exitCode !== 0) {
                console.log("[codexbar-workers] bridge failed", sourceName, stderr);
                root.errorMessage = stderr.length > 0 ? stderr.trim() : i18n("Bridge command failed");
                return;
            }

            root.parsePayload(stdout);
        }
    }

    PlasmaCore.Action {
        id: refreshAction
        text: i18n("Refresh")
        icon.name: "view-refresh"
        onTriggered: root.refresh()
    }

    Plasmoid.contextualActions: [
        refreshAction
    ]
}
