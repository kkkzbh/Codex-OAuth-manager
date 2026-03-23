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
    readonly property string collectorPathExpanded: {
        const configured = Plasmoid.configuration.collectorPath || "~/.local/bin/codexbar-collector";
        const expanded = configured.startsWith("~") ? homePath + configured.slice(1) : configured;
        return normalizePath(expanded);
    }
    readonly property string collectorDir: collectorPathExpanded.lastIndexOf("/") > 0
        ? collectorPathExpanded.slice(0, collectorPathExpanded.lastIndexOf("/"))
        : homePath + "/.local/bin"
    readonly property string bridgePath: homePath + "/.local/bin/codexbar-plasmoid-bridge"
    readonly property int refreshIntervalSeconds: 3
    readonly property string collectorCommand: "env PATH="
        + shellQuote(collectorDir + ":/usr/local/bin:/usr/bin:/bin")
        + " COLLECTOR_PATH="
        + shellQuote(collectorPathExpanded)
        + " REFRESH_INTERVAL_SECONDS="
        + shellQuote(String(refreshIntervalSeconds))
        + " "
        + shellQuote(bridgePath)
    readonly property string commandSource: "sh -lc " + shellQuote(collectorCommand)

    property bool isLoading: true
    property string errorMessage: ""
    property var snapshot: ({
        generatedAt: "",
        totalTokens: 0,
        formattedTotalTokens: "--",
        tokensToday: 0,
        tokens7d: 0,
        tokens30d: 0,
        sources: [],
        availableSourceCount: 0,
        unavailableSourceCount: 0,
        status: "error",
        error: null
    })

    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.title: i18n("CodexBar Tokens")
    Plasmoid.icon: "utilities-terminal"
    toolTipMainText: i18n("CodexBar Tokens")
    toolTipSubText: {
        if (errorMessage.length > 0) {
            return errorMessage;
        }
        if (isLoading) {
            return i18n("Loading local token totals…");
        }
        return i18n("%1 Tokens · %2", snapshot.formattedTotalTokens, relativeTimestamp(snapshot.generatedAt));
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
            snapshot = JSON.parse(stdout);
            errorMessage = snapshot.error ? String(snapshot.error) : "";
            isLoading = false;
        } catch (error) {
            console.log("[codexbar] invalid collector payload", stdout);
            errorMessage = i18n("Invalid collector payload");
            isLoading = false;
        }
    }

    function relativeTimestamp(value) {
        if (!value) {
            return i18n("Updated recently");
        }

        const diffSeconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000));
        if (diffSeconds < 5) {
            return i18n("Updated just now");
        }
        if (diffSeconds < 60) {
            return i18n("Updated %1s ago", diffSeconds);
        }
        if (diffSeconds < 3600) {
            return i18n("Updated %1m ago", Math.floor(diffSeconds / 60));
        }
        return i18n("Updated %1h ago", Math.floor(diffSeconds / 3600));
    }

    function sourceStatusText(source) {
        return source.available ? i18n("Available") : i18n("Unavailable");
    }

    function formatInteger(value) {
        return Number(value || 0).toLocaleString(Qt.locale("en_US"), "f", 0);
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
        interval: root.refreshIntervalSeconds * 1000
        connectedSources: root.commandSource.length > 0 ? [root.commandSource] : []

        onNewData: function(sourceName, data) {
            const exitCode = Number(data["exit code"] ?? data.exitCode ?? 0);
            const stdout = String(data.stdout ?? "");
            const stderr = String(data.stderr ?? "");

            if (exitCode !== 0) {
                console.log("[codexbar] collector failed", sourceName, stderr);
                root.errorMessage = stderr.length > 0 ? stderr.trim() : i18n("Collector command failed");
                root.isLoading = false;
                return;
            }

            root.parsePayload(stdout);
        }
    }

    Component.onCompleted: {
        console.log("[codexbar] command source", commandSource);
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
