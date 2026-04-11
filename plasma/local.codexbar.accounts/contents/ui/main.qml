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
    readonly property int refreshIntervalSeconds: Math.max(10, Plasmoid.configuration.refreshIntervalSeconds || 120)
    readonly property int warnPercent: Plasmoid.configuration.warnPercent || 75
    readonly property int dangerPercent: Plasmoid.configuration.dangerPercent || 90
    readonly property int liveFetchConcurrency: Math.max(1, Plasmoid.configuration.liveFetchConcurrency || 4)
    readonly property int liveFetchTimeoutSeconds: Math.max(3, Plasmoid.configuration.liveFetchTimeoutSeconds || 12)
    readonly property bool autoSwitchEnabled: Plasmoid.configuration.enableAutoSwitch || false
    readonly property int autoSwitch5hThreshold: Plasmoid.configuration.autoSwitch5hThreshold || 10
    readonly property int autoSwitchWeeklyThreshold: Plasmoid.configuration.autoSwitchWeeklyThreshold || 5
    readonly property string terminalCommand: Plasmoid.configuration.terminalCommand || "kitty -e {command}"
    readonly property string loginCommand: Plasmoid.configuration.loginCommand || "codex login"
    readonly property int currentRefreshCooldownMs: Math.max(3 * 60 * 1000, refreshIntervalSeconds * 2000)
    readonly property var snapshot: mergedSnapshotForDisplay(allSnapshot, activeSnapshot)
    readonly property var currentAccount: currentAccountFromSnapshotData(snapshot)
    readonly property int knownAccountCount: Math.max(
        1,
        Number(snapshot && snapshot.accountCount ? snapshot.accountCount : 0)
        || Number(allSnapshot && allSnapshot.accountCount ? allSnapshot.accountCount : 0)
        || Number(snapshot && snapshot.accounts ? snapshot.accounts.length : 0)
        || Number(allSnapshot && allSnapshot.accounts ? allSnapshot.accounts.length : 0)
        || 1
    )
    readonly property string snapshotGeneratedAt: snapshot && snapshot.generatedAt ? String(snapshot.generatedAt) : ""
    readonly property string currentAccountGeneratedAt: accountTimestamp(currentAccount)
    readonly property int currentAccountSessionPercent: usagePercent(currentAccount, "session")
    readonly property int currentAccountWeeklyPercent: usagePercent(currentAccount, "weekly")
    readonly property string currentAccountSessionLabel: usageLabel(currentAccount, "session")
    readonly property string currentAccountWeeklyLabel: usageLabel(currentAccount, "weekly")

    property bool isLoading: true
    property bool actionInFlight: false
    property string errorMessage: ""
    property string pendingAction: ""
    property string pendingSnapshotAccountKey: ""
    property int commandInvocationSerial: 0
    property double lastAutoSwitchAtMs: 0
    property var activeSnapshot: ({
        generatedAt: "",
        status: "error",
        error: null,
        activeAccountKey: "",
        accountCount: 0,
        healthyAccountCount: 0,
        staleAccountCount: 0,
        accounts: []
    })
    property var allSnapshot: ({
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
        if (actionInFlight) {
            return i18n("Refreshing account limits…");
        }
        if (!currentAccount) {
            return i18n("No active Codex account");
        }
        return i18n("%1 · 5h %2% · 1w %3% · %4 · %5",
                    displayName(currentAccount),
                    currentAccountSessionPercent,
                    currentAccountWeeklyPercent,
                    currentAccount.usageSource === "live" ? i18n("Live") : i18n("Cached"),
                    relativeTimestamp(currentAccountGeneratedAt));
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
            + " LOGIN_COMMAND=" + shellQuote(loginCommand)
            + " AUTO_SWITCH_5H_THRESHOLD=" + shellQuote(String(autoSwitch5hThreshold))
            + " AUTO_SWITCH_WEEKLY_THRESHOLD=" + shellQuote(String(autoSwitchWeeklyThreshold))
            + " " + shellQuote(bridgePathExpanded)
            + " " + shellQuote(commandName)
            + args;
    }

    function fullRefreshTimeoutSeconds() {
        const baselineAccountCount = Math.max(knownAccountCount, liveFetchConcurrency * 3, 12);
        return Math.ceil(Math.max(baselineAccountCount, 1) / liveFetchConcurrency) * liveFetchTimeoutSeconds + 5;
    }

    function isFullSnapshotAction(actionName) {
        return actionName === "snapshot-all"
            || actionName === "snapshot-background"
            || actionName === "snapshot-resync";
    }

    function requestTimeoutMs(actionName) {
        if (isFullSnapshotAction(actionName)) {
            return Math.max(5000, fullRefreshTimeoutSeconds() * 1000);
        }
        if (actionName === "snapshot-account" || actionName === "snapshot-active") {
            return Math.max(5000, (liveFetchTimeoutSeconds + 5) * 1000);
        }
        return 0;
    }

    function timeoutMessage(actionName) {
        const seconds = Math.max(1, Math.round(requestTimeoutMs(actionName) / 1000));
        return i18n("Refreshing account limits timed out after %1s", seconds);
    }

    function clearRequestState() {
        pendingAction = "";
        pendingSnapshotAccountKey = "";
        actionInFlight = false;
        requestWatchdog.stop();
    }

    function runCommand(actionName, commandName, extraArgs, expectSnapshot, snapshotAccountKey) {
        if (actionInFlight) {
            return false;
        }
        errorMessage = "";
        pendingAction = actionName;
        pendingSnapshotAccountKey = snapshotAccountKey ? String(snapshotAccountKey) : "";
        actionInFlight = true;
        if (expectSnapshot) {
            isLoading = true;
        }
        commandInvocationSerial += 1;
        const invocationNonce = String(Date.now()) + "-" + String(commandInvocationSerial);
        const invocationCommand = "env CODEXBAR_REQUEST_NONCE="
            + shellQuote(invocationNonce)
            + " "
            + buildBridgeCommand(commandName, extraArgs);
        executable.connectedSources = [];
        executable.connectedSources = ["sh -lc " + shellQuote(invocationCommand)];
        if (expectSnapshot) {
            requestWatchdog.interval = requestTimeoutMs(actionName);
            requestWatchdog.restart();
        } else {
            requestWatchdog.stop();
        }
        return true;
    }

    function refreshAll(forceRefresh, actionName) {
        const args = [];
        if (forceRefresh) {
            args.push("--force-refresh");
        }
        return runCommand(actionName || "snapshot-all", "snapshot", args, true, "");
    }

    function refreshAccount(accountKey) {
        return runCommand(
            "snapshot-account",
            "snapshot",
            ["--force-refresh", "--account-key", shellQuote(accountKey)],
            true,
            accountKey
        );
    }

    function refreshBackground() {
        // Background polling keeps every account row fresh, but it should still
        // respect collector backoff for accounts that are consistently failing.
        refreshAll(false, "snapshot-background");
    }

    function addAccount() {
        runCommand("login", "login", [], false, "");
    }

    function activateAccount(accountKey) {
        // Optimistically flip the active flag locally so the UI updates the
        // moment the user clicks Switch, instead of waiting for the activate
        // command + follow-up snapshot to round-trip through the collector.
        applyOptimisticActive(accountKey);
        runCommand("activate", "activate", ["--account-key", shellQuote(accountKey)], false, "");
    }

    function applyOptimisticActive(accountKey) {
        activeSnapshot = withActiveAccount(activeSnapshot, accountKey);
        allSnapshot = withActiveAccount(allSnapshot, accountKey);
    }

    function withActiveAccount(snapshotData, accountKey) {
        if (!snapshotData || !snapshotData.accounts) {
            return snapshotData;
        }
        const updatedAccounts = snapshotData.accounts.map(function(account) {
            const isActive = account.accountKey === accountKey;
            if (account.isActive === isActive) {
                return account;
            }
            return Object.assign({}, account, { isActive: isActive });
        });
        return Object.assign({}, snapshotData, {
            accounts: updatedAccounts,
            activeAccountKey: accountKey
        });
    }

    function removeAccount(accountKey) {
        runCommand("remove", "remove", ["--account-key", shellQuote(accountKey)], false, "");
    }

    function warmupAccount(accountKey) {
        // Sends a tiny Responses-API request as that account so OpenAI starts
        // its rolling 5h rate-limit window. The default post-action handler
        // (`onNewData`) then runs `refreshAll(true)`, which re-fetches usage
        // for every account and surfaces the new 5h bar value.
        runCommand("warmup", "warmup", ["--account-key", shellQuote(accountKey)], false, "");
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
        runCommand("auto-switch", "auto-switch", ["--force-refresh"], false, "");
    }

    function snapshotHasAccounts(snapshotData) {
        return !!(snapshotData && snapshotData.accounts && snapshotData.accounts.length > 0);
    }

    function parseSnapshotPayload(stdout) {
        try {
            const parsed = JSON.parse(stdout);
            if (!parsed.accounts) parsed.accounts = [];
            logActiveAccountDiagnostics(parsed);
            return parsed;
        } catch (error) {
            console.log("[codexbar-accounts] invalid payload", stdout);
            errorMessage = i18n("Invalid collector payload");
            isLoading = false;
            return null;
        }
    }

    function parseSnapshot(stdout, activeOnly) {
        const parsed = parseSnapshotPayload(stdout);
        if (!parsed) {
            return null;
        }
        if (activeOnly) {
            activeSnapshot = parsed;
        } else {
            allSnapshot = parsed;
        }
        errorMessage = parsed.error ? String(parsed.error) : "";
        isLoading = false;
        return parsed;
    }

    function accountKey(account) {
        return account && account.accountKey ? String(account.accountKey) : "";
    }

    function activeAccountKeyFromSnapshot(snapshotData) {
        if (snapshotData && snapshotData.activeAccountKey) {
            return String(snapshotData.activeAccountKey);
        }

        const accounts = snapshotData && snapshotData.accounts ? snapshotData.accounts : [];
        for (let index = 0; index < accounts.length; index += 1) {
            if (accounts[index].isActive) {
                return accountKey(accounts[index]);
            }
        }

        return "";
    }

    function accountForKey(snapshotData, key) {
        if (!snapshotData || !snapshotData.accounts || !key) {
            return null;
        }

        for (let index = 0; index < snapshotData.accounts.length; index += 1) {
            if (accountKey(snapshotData.accounts[index]) === key) {
                return snapshotData.accounts[index];
            }
        }

        return null;
    }

    function timestampMs(value) {
        if (!value) {
            return 0;
        }
        const parsed = new Date(String(value)).getTime();
        return Number.isFinite(parsed) ? parsed : 0;
    }

    function accountTimestamp(account) {
        if (!account) {
            return "";
        }
        const generatedAt = account.generatedAt ? String(account.generatedAt) : "";
        const lastUsageAt = account.lastUsageAt ? String(account.lastUsageAt) : "";
        return timestampMs(lastUsageAt) >= timestampMs(generatedAt)
            ? (lastUsageAt || generatedAt)
            : (generatedAt || lastUsageAt);
    }

    function preferAccountSnapshot(primary, secondary) {
        if (!primary) {
            return secondary;
        }
        if (!secondary) {
            return primary;
        }

        const primaryScore = timestampMs(accountTimestamp(primary));
        const secondaryScore = timestampMs(accountTimestamp(secondary));
        if (secondaryScore > primaryScore) {
            return secondary;
        }
        if (primaryScore > secondaryScore) {
            return primary;
        }

        if (primary.usageSource !== secondary.usageSource) {
            return secondary.usageSource === "live" ? secondary : primary;
        }

        return primary;
    }

    function withSnapshotSummary(snapshotData, generatedAt, errorText) {
        const accounts = snapshotData && snapshotData.accounts ? snapshotData.accounts : [];
        let healthyAccountCount = 0;
        let staleAccountCount = 0;
        let hasErrorAccount = false;

        for (let index = 0; index < accounts.length; index += 1) {
            const status = String(accounts[index].status || "error");
            if (status === "ok") {
                healthyAccountCount += 1;
            } else if (status === "stale") {
                staleAccountCount += 1;
            } else {
                hasErrorAccount = true;
            }
        }

        let status = snapshotData && snapshotData.status ? String(snapshotData.status) : "ok";
        if (accounts.length > 0) {
            status = healthyAccountCount > 0
                ? (staleAccountCount > 0 || hasErrorAccount ? "stale" : "ok")
                : "error";
        }

        const nextError = typeof errorText === "string"
            ? (errorText.length > 0 ? errorText : null)
            : (snapshotData && snapshotData.error ? snapshotData.error : null);
        const nextGeneratedAt = generatedAt && String(generatedAt).length > 0
            ? String(generatedAt)
            : (snapshotData && snapshotData.generatedAt ? String(snapshotData.generatedAt) : "");

        return Object.assign({}, snapshotData, {
            generatedAt: nextGeneratedAt,
            status: status,
            error: nextError,
            activeAccountKey: activeAccountKeyFromSnapshot(snapshotData),
            accountCount: accounts.length,
            healthyAccountCount: healthyAccountCount,
            staleAccountCount: staleAccountCount
        });
    }

    function replaceAccountInSnapshot(snapshotData, account, generatedAt, errorText) {
        if (!snapshotHasAccounts(snapshotData) || !account) {
            return snapshotData;
        }

        const targetKey = accountKey(account);
        if (targetKey.length === 0) {
            return snapshotData;
        }

        let replaced = false;
        const mergedAccounts = snapshotData.accounts.map(function(existingAccount) {
            if (accountKey(existingAccount) !== targetKey) {
                return existingAccount;
            }
            replaced = true;
            return account;
        });

        if (!replaced) {
            return snapshotData;
        }

        return withSnapshotSummary(Object.assign({}, snapshotData, {
            accounts: mergedAccounts
        }), generatedAt, errorText);
    }

    function parseSingleAccountSnapshot(stdout, expectedAccountKey) {
        const parsed = parseSnapshotPayload(stdout);
        if (!parsed) {
            return null;
        }

        const account = parsed.accounts.length > 0 ? parsed.accounts[0] : null;
        const targetKey = expectedAccountKey && expectedAccountKey.length > 0
            ? String(expectedAccountKey)
            : accountKey(account);
        const currentKey = accountKey(currentAccount);
        const parsedError = parsed.error ? String(parsed.error) : "";
        const parsedGeneratedAt = parsed.generatedAt ? String(parsed.generatedAt) : "";

        if (!account || targetKey.length === 0) {
            errorMessage = parsedError.length > 0 ? parsedError : i18n("No account data available");
            isLoading = false;
            return null;
        }

        if (accountKey(account) !== targetKey) {
            console.warn("[codexbar-accounts] refreshed account key `" + accountKey(account)
                + "` did not match requested `" + targetKey + "`");
        }

        if (!accountForKey(snapshot, targetKey)) {
            console.warn("[codexbar-accounts] refreshed account `" + targetKey
                + "` was not found in current snapshot; scheduling resync");
            errorMessage = parsedError;
            isLoading = false;
            refreshAll(false, "snapshot-resync");
            return parsed;
        }

        if (accountForKey(allSnapshot, targetKey)) {
            allSnapshot = replaceAccountInSnapshot(allSnapshot, account, parsedGeneratedAt, parsedError);
        }

        if (targetKey === currentKey && accountForKey(activeSnapshot, targetKey)) {
            activeSnapshot = replaceAccountInSnapshot(activeSnapshot, account, parsedGeneratedAt, parsedError);
        }

        errorMessage = parsedError;
        isLoading = false;

        if (!accountForKey(allSnapshot, targetKey) && snapshotHasAccounts(allSnapshot)) {
            refreshAll(false, "snapshot-resync");
        }

        return parsed;
    }

    function mergedSnapshotForDisplay(allSnapshotData, activeSnapshotData) {
        const baseSnapshot = snapshotHasAccounts(allSnapshotData)
            ? allSnapshotData
            : activeSnapshotData;
        if (!snapshotHasAccounts(baseSnapshot)) {
            return baseSnapshot;
        }

        const activeKey = activeAccountKeyFromSnapshot(baseSnapshot);
        const preferredCurrent = preferAccountSnapshot(
            accountForKey(allSnapshotData, activeKey),
            accountForKey(activeSnapshotData, activeKey)
        );
        return replaceAccountInSnapshot(
            baseSnapshot,
            preferredCurrent || currentAccountFromSnapshotData(baseSnapshot)
        );
    }

    function currentAccountFromSnapshotData(snapshotData) {
        const accounts = snapshotData && snapshotData.accounts ? snapshotData.accounts : [];
        const activeAccountKey = snapshotData && snapshotData.activeAccountKey
            ? String(snapshotData.activeAccountKey)
            : "";
        if (activeAccountKey.length > 0) {
            for (let index = 0; index < accounts.length; index += 1) {
                if (accountKey(accounts[index]) === activeAccountKey) {
                    return accounts[index];
                }
            }
        }
        for (let index = 0; index < accounts.length; index += 1) {
            if (accounts[index].isActive) {
                return accounts[index];
            }
        }
        return accounts.length > 0 ? accounts[0] : null;
    }

    function isCurrentAccount(account) {
        return accountKey(account).length > 0
            && accountKey(account) === accountKey(currentAccount);
    }

    function usageWindow(account, windowName) {
        if (!account) {
            return null;
        }
        if (windowName === "session") {
            return account.session || null;
        }
        if (windowName === "weekly") {
            return account.weekly || null;
        }
        console.warn("[codexbar-accounts] unknown usage window `" + String(windowName) + "`");
        return null;
    }

    function usagePercent(account, windowName) {
        const window = usageWindow(account, windowName);
        return window ? Number(window.usedPercent || 0) : 0;
    }

    function usageLabel(account, windowName) {
        const window = usageWindow(account, windowName);
        return window
            ? i18n("%1% · %2", window.usedPercent, window.resetsInLabel)
            : "--";
    }

    function logActiveAccountDiagnostics(snapshotData) {
        const accounts = snapshotData && snapshotData.accounts ? snapshotData.accounts : [];
        if (accounts.length === 0) {
            return;
        }

        const activeAccountKey = snapshotData && snapshotData.activeAccountKey
            ? String(snapshotData.activeAccountKey)
            : "";
        let activeKeyMatch = null;
        const flaggedKeys = [];

        for (let index = 0; index < accounts.length; index += 1) {
            const key = accountKey(accounts[index]);
            if (activeAccountKey.length > 0 && key === activeAccountKey) {
                activeKeyMatch = accounts[index];
            }
            if (accounts[index].isActive) {
                flaggedKeys.push(key);
            }
        }

        if (activeAccountKey.length > 0 && !activeKeyMatch) {
            console.warn("[codexbar-accounts] snapshot activeAccountKey `" + activeAccountKey + "` was not found in accounts");
        }

        if (flaggedKeys.length > 1) {
            const resolvedKey = activeKeyMatch
                ? accountKey(activeKeyMatch)
                : flaggedKeys[0];
            console.warn("[codexbar-accounts] snapshot reported multiple active accounts [" + flaggedKeys.join(", ")
                + "]; resolving to `" + resolvedKey + "`");
        }
    }

    function displayName(account) {
        if (!account) {
            return "";
        }
        return account.alias && account.alias.length > 0 ? account.alias : account.email;
    }

    function workspaceName(account) {
        if (!account || !account.workspaceName) {
            return "";
        }
        return String(account.workspaceName).trim();
    }

    function isTeamAccount(account) {
        return !!account && String(account.plan || "").toLowerCase() === "team";
    }

    function accountWorkspaceText(account) {
        const name = workspaceName(account);
        if (!isTeamAccount(account) || name.length === 0) {
            return "";
        }
        return i18n("Workspace: %1", name);
    }

    function accountSecondaryText(account, includePlan) {
        if (!account) {
            return "";
        }
        const parts = [];
        if (account.email && String(account.email).length > 0) {
            parts.push(String(account.email));
        }
        const workspace = accountWorkspaceText(account);
        if (workspace.length > 0) {
            parts.push(workspace);
        }
        if (includePlan && account.plan && String(account.plan).length > 0) {
            parts.push(String(account.plan));
        }
        parts.push(account.usageSource === "live" ? i18n("Live") : i18n("Cached"));
        return parts.join(" · ");
    }

    function accountErrorText(account) {
        return account && account.error ? String(account.error).trim() : "";
    }

    function isLiveAccountSnapshot(account) {
        return !!account && account.status === "ok" && account.usageSource === "live";
    }

    function isCachedAccountSnapshot(account) {
        return !!account && account.usageSource === "cache" && !isLiveAccountSnapshot(account);
    }

    function joinSummaryParts(parts) {
        return parts.filter(function(part) {
            return String(part || "").length > 0;
        }).join(" · ");
    }

    function currentAccountStatusText() {
        if (!currentAccount) {
            return i18n("No account data available");
        }
        if (isLiveAccountSnapshot(currentAccount)) {
            return joinSummaryParts([
                i18n("Live"),
                relativeTimestamp(currentAccountGeneratedAt)
            ]);
        }
        const errorText = accountErrorText(currentAccount);
        return joinSummaryParts([
            i18n("Showing cached data from %1", relativeTimestamp(currentAccountGeneratedAt)),
            errorText
        ]);
    }

    function currentAccountSubtitle() {
        if (actionInFlight) {
            return isFullSnapshotAction(pendingAction)
                ? i18n("Refreshing all account limits…")
                : i18n("Refreshing account limits…");
        }
        if (!currentAccount) {
            return i18n("No account data available");
        }
        return joinSummaryParts([
            currentAccount.plan,
            currentAccountStatusText()
        ]);
    }

    function footerStatusText() {
        if (actionInFlight) {
            return isFullSnapshotAction(pendingAction)
                ? i18n("Refreshing all account limits…")
                : i18n("Refreshing account limits…");
        }
        if (isCachedAccountSnapshot(currentAccount)) {
            const errorText = accountErrorText(currentAccount);
            return joinSummaryParts([
                i18n("Showing cached data from %1", relativeTimestamp(currentAccountGeneratedAt)),
                errorText
            ]);
        }
        return relativeTimestamp(snapshotGeneratedAt);
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
            const snapshotAccountKey = root.pendingSnapshotAccountKey;
            root.clearRequestState();

            if (exitCode !== 0) {
                root.errorMessage = stderr.length > 0 ? stderr.trim() : i18n("Command failed");
                root.isLoading = false;
                return;
            }

            if (root.isFullSnapshotAction(action) || action === "snapshot-active") {
                root.parseSnapshot(stdout, false);
                if (root.autoSwitchEnabled && action === "snapshot-background") {
                    root.maybeAutoSwitch();
                }
                return;
            }

            if (action === "snapshot-account") {
                root.parseSingleAccountSnapshot(stdout, snapshotAccountKey);
                return;
            }

            // For activate/remove the cached usage data is still valid — only the
            // active flag changes, which the collector reads fresh from the registry
            // on every snapshot. Skip --force-refresh so the panel updates immediately
            // instead of waiting for live HTTP fetches across every account.
            const skipForce = action === "activate" || action === "remove";
            root.refreshAll(!skipForce);
        }
    }

    Timer {
        id: pollTimer
        interval: root.refreshIntervalSeconds * 1000
        repeat: true
        running: true
        onTriggered: root.refreshBackground()
    }

    Timer {
        id: requestWatchdog
        interval: (root.liveFetchTimeoutSeconds + 5) * 1000
        repeat: false
        onTriggered: {
            if (!root.actionInFlight) {
                return;
            }
            const action = root.pendingAction;
            console.warn("[codexbar-accounts] request watchdog fired for `" + action + "`");
            executable.connectedSources = [];
            root.errorMessage = root.timeoutMessage(action);
            root.isLoading = false;
            root.clearRequestState();
        }
    }

    Component.onCompleted: refreshAll(true)

    PlasmaCore.Action {
        id: refreshAction
        text: root.actionInFlight ? i18n("Refreshing…") : i18n("Refresh all")
        icon.name: "view-refresh"
        enabled: !root.actionInFlight
        onTriggered: root.refreshAll(true)
    }

    PlasmaCore.Action {
        id: addAccountAction
        text: i18n("Add account")
        icon.name: "list-add"
        enabled: !root.actionInFlight
        onTriggered: root.addAccount()
    }

    Plasmoid.contextualActions: [
        refreshAction,
        addAccountAction
    ]
}
