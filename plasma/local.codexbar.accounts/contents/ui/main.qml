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
    readonly property string bridgePathExpanded: expandPath(Plasmoid.configuration.bridgePath || "~/.local/bin/codexbar-accounts-plasmoid-bridge")
    readonly property string bridgeDir: bridgePathExpanded.lastIndexOf("/") > 0
        ? bridgePathExpanded.slice(0, bridgePathExpanded.lastIndexOf("/"))
        : homePath + "/.local/bin"
    readonly property string collectorPathExpanded: expandPath(Plasmoid.configuration.collectorPath || "~/.local/bin/codexbar-collector")
    readonly property string codexHomePathExpanded: expandPath(Plasmoid.configuration.codexHomePath || "~/.codex")
    readonly property int refreshIntervalSeconds: Math.max(30, Plasmoid.configuration.refreshIntervalSeconds || 90)
    readonly property int warnPercent: Plasmoid.configuration.warnPercent || 75
    readonly property int dangerPercent: Plasmoid.configuration.dangerPercent || 90
    readonly property int liveFetchConcurrency: Math.max(1, Plasmoid.configuration.liveFetchConcurrency || 4)
    readonly property int liveFetchTimeoutSeconds: Math.max(3, Plasmoid.configuration.liveFetchTimeoutSeconds || 8)
    readonly property bool liveFetchOnExpand: Plasmoid.configuration.liveFetchOnExpand !== false
    readonly property bool autoSwitchEnabled: Plasmoid.configuration.enableAutoSwitch || false
    readonly property int autoSwitch5hThreshold: Plasmoid.configuration.autoSwitch5hThreshold || 10
    readonly property int autoSwitchWeeklyThreshold: Plasmoid.configuration.autoSwitchWeeklyThreshold || 5
    readonly property string terminalCommand: Plasmoid.configuration.terminalCommand || "konsole -e {command}"
    readonly property var currentAccount: currentAccountFromSnapshot()
    readonly property int currentAccountSessionPercent: currentAccount && currentAccount.session ? currentAccount.session.usedPercent : 0
    readonly property int currentAccountWeeklyPercent: currentAccount && currentAccount.weekly ? currentAccount.weekly.usedPercent : 0
    readonly property string currentAccountSessionLabel: currentAccount && currentAccount.session ? i18n("%1% · %2", currentAccount.session.usedPercent, currentAccount.session.resetsInLabel) : "--"
    readonly property string currentAccountWeeklyLabel: currentAccount && currentAccount.weekly ? i18n("%1% · %2", currentAccount.weekly.usedPercent, currentAccount.weekly.resetsInLabel) : "--"

    property bool isLoading: true
    property bool actionInFlight: false
    property string errorMessage: ""
    property string pendingAction: ""
    property int commandInvocationSerial: 0
    property double lastAutoSwitchAtMs: 0
    property var snapshot: ({
        generatedAt: "",
        status: "error",
        error: null,
        activeAccountKey: "",
        accountCount: 0,
        healthyAccountCount: 0,
        staleAccountCount: 0,
        accounts: []
    })

    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.title: i18n("CodexBar Accounts")
    Plasmoid.icon: "codex-app"
    toolTipMainText: i18n("CodexBar Accounts")
    toolTipSubText: {
        if (errorMessage.length > 0) {
            return errorMessage;
        }
        if (isLoading) {
            return i18n("Loading Codex account limits…");
        }
        if (!currentAccount) {
            return i18n("No active Codex account");
        }
        return i18n("%1 · 5h %2% · 1w %3% · %4 · %5",
                    displayName(currentAccount),
                    currentAccountSessionPercent,
                    currentAccountWeeklyPercent,
                    currentAccount.usageSource === "live" ? i18n("Live") : i18n("Cached"),
                    relativeTimestamp(snapshot.generatedAt));
    }

    function expandPath(pathValue) {
        const normalized = normalizePath(pathValue);
        return normalized.startsWith("~") ? homePath + normalized.slice(1) : normalized;
    }

    function normalizePath(value) {
        let normalized = String(value || "").trim();
        if (normalized.startsWith("file://")) {
            normalized = normalized.slice("file://".length);
        }
        return normalized;
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\"'\"'") + "'";
    }

    function buildBridgeCommand(commandName, extraArgs) {
        const args = extraArgs && extraArgs.length > 0 ? " " + extraArgs.join(" ") : "";
        return "env PATH="
            + shellQuote(bridgeDir + ":/usr/local/bin:/usr/bin:/bin")
            + " COLLECTOR_PATH=" + shellQuote(collectorPathExpanded)
            + " CODEX_HOME_PATH=" + shellQuote(codexHomePathExpanded)
            + " REFRESH_INTERVAL_SECONDS=" + shellQuote(String(refreshIntervalSeconds))
            + " FETCH_CONCURRENCY=" + shellQuote(String(liveFetchConcurrency))
            + " FETCH_TIMEOUT_SECONDS=" + shellQuote(String(liveFetchTimeoutSeconds))
            + " TERMINAL_COMMAND=" + shellQuote(terminalCommand)
            + " AUTO_SWITCH_5H_THRESHOLD=" + shellQuote(String(autoSwitch5hThreshold))
            + " AUTO_SWITCH_WEEKLY_THRESHOLD=" + shellQuote(String(autoSwitchWeeklyThreshold))
            + " " + shellQuote(bridgePathExpanded)
            + " " + shellQuote(commandName)
            + args;
    }

    function runCommand(actionName, commandName, extraArgs, expectSnapshot) {
        pendingAction = actionName;
        actionInFlight = !expectSnapshot;
        commandInvocationSerial += 1;
        const invocationNonce = String(Date.now()) + "-" + String(commandInvocationSerial);
        const invocationCommand = "env CODEXBAR_REQUEST_NONCE="
            + shellQuote(invocationNonce)
            + " "
            + buildBridgeCommand(commandName, extraArgs);
        executable.connectedSources = [];
        executable.connectedSources = ["sh -lc " + shellQuote(invocationCommand)];
    }

    function refreshCurrent(forceRefresh) {
        const args = ["--active-only"];
        if (forceRefresh) {
            args.push("--force-refresh");
        }
        runCommand("snapshot-active", "snapshot", args, true);
    }

    function refreshAll(forceRefresh) {
        const args = [];
        if (forceRefresh) {
            args.push("--force-refresh");
        }
        runCommand("snapshot-all", "snapshot", args, true);
    }

    function addAccount() {
        runCommand("login", "login", [], false);
    }

    function activateAccount(accountKey) {
        runCommand("activate", "activate", ["--account-key", shellQuote(accountKey)], false);
    }

    function removeAccount(accountKey) {
        runCommand("remove", "remove", ["--account-key", shellQuote(accountKey)], false);
    }

    function maybeAutoSwitch() {
        if (!autoSwitchEnabled || actionInFlight) {
            return;
        }
        const now = Date.now();
        if (now - lastAutoSwitchAtMs < refreshIntervalSeconds * 1000) {
            return;
        }
        lastAutoSwitchAtMs = now;
        runCommand("auto-switch", "auto-switch", ["--force-refresh"], false);
    }

    function parseSnapshot(stdout) {
        try {
            const parsed = JSON.parse(stdout);
            if (!parsed.accounts) parsed.accounts = [];
            snapshot = parsed;
            errorMessage = parsed.error ? String(parsed.error) : "";
            isLoading = false;
        } catch (error) {
            console.log("[codexbar-accounts] invalid payload", stdout);
            errorMessage = i18n("Invalid collector payload");
            isLoading = false;
        }
    }

    function currentAccountFromSnapshot() {
        const accounts = snapshot.accounts || [];
        for (let index = 0; index < accounts.length; index += 1) {
            if (accounts[index].isActive) {
                return accounts[index];
            }
        }
        return accounts.length > 0 ? accounts[0] : null;
    }

    function displayName(account) {
        if (!account) {
            return "";
        }
        return account.alias && account.alias.length > 0 ? account.alias : account.email;
    }

    function currentAccountSubtitle() {
        if (!currentAccount) {
            return i18n("No account data available");
        }
        return i18n("%1 · %2 · %3",
                    currentAccount.plan,
                    currentAccount.usageSource === "live" ? i18n("Live") : i18n("Cached"),
                    relativeTimestamp(currentAccount.generatedAt || snapshot.generatedAt));
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

    function barColor(percent) {
        if (percent >= dangerPercent) return Qt.rgba(0.90, 0.30, 0.24, 1.0);
        if (percent >= warnPercent) return Qt.rgba(0.96, 0.66, 0.18, 1.0);
        return Kirigami.Theme.highlightColor;
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
        interval: 0

        onNewData: function(sourceName, data) {
            const exitCode = Number(data["exit code"] ?? data.exitCode ?? 0);
            const stdout = String(data.stdout ?? "");
            const stderr = String(data.stderr ?? "");
            const action = root.pendingAction;
            root.pendingAction = "";

            if (exitCode !== 0) {
                root.errorMessage = stderr.length > 0 ? stderr.trim() : i18n("Command failed");
                root.actionInFlight = false;
                root.isLoading = false;
                return;
            }

            if (action === "snapshot-active" || action === "snapshot-all") {
                root.parseSnapshot(stdout);
                root.actionInFlight = false;
                if (root.autoSwitchEnabled && action === "snapshot-active") {
                    root.maybeAutoSwitch();
                }
                return;
            }

            root.actionInFlight = false;
            root.refreshAll(true);
        }
    }

    Timer {
        id: pollTimer
        interval: root.refreshIntervalSeconds * 1000
        repeat: true
        running: true
        onTriggered: root.refreshCurrent(true)
    }

    onExpandedChanged: function() {
        if (root.expanded && liveFetchOnExpand) {
            refreshAll(true);
        }
    }

    Component.onCompleted: refreshCurrent(true)

    PlasmaCore.Action {
        id: refreshAction
        text: i18n("Refresh all")
        icon.name: "view-refresh"
        onTriggered: root.refreshAll(true)
    }

    PlasmaCore.Action {
        id: addAccountAction
        text: i18n("Add account")
        icon.name: "list-add"
        onTriggered: root.addAccount()
    }

    Plasmoid.contextualActions: [
        refreshAction,
        addAccountAction
    ]
}
