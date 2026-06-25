import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    Plasmoid.icon: "view-statistics"
    Plasmoid.title: "CodexBar"
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refreshNow()
        }
    ]

    property string commandPath: (Plasmoid.configuration.commandPath || "codexbar").trim()
    property string provider: (Plasmoid.configuration.provider || "").trim()
    property string source: (Plasmoid.configuration.source || "").trim()
    property int refreshIntervalSec: Math.max(10, Plasmoid.configuration.refreshInterval || 300)
    property bool includeStatus: Plasmoid.configuration.includeStatus
    property bool usageBarsShowUsed: Plasmoid.configuration.usageBarsShowUsed === true
    property bool showProviderChangelogs: Plasmoid.configuration.showProviderChangelogs === true
    property var providers: []
    property var providerDisplayNames: ({})
    property string errorText: ""
    property string lastUpdatedText: ""
    property bool loading: false
    property string commandSource: buildCommand()
    property string connectedCommandSource: ""
    property string providerConfigCommandSource: buildProviderConfigCommand()
    property string connectedProviderConfigCommandSource: ""
    property var pendingProviderCommands: ({})
    property var fallbackProviderOrder: []
    property var fallbackProviderResults: ({})
    property var fallbackProviderSeen: ({})
    property int pendingProviderCount: 0
    property bool providerFallbackActive: false
    property string costCommandSource: buildCostCommand()
    property string connectedCostCommandSource: ""
    property var tokenCosts: ({})
    property string costErrorText: ""
    property int selectedProviderIndex: 0
    property bool selectionInitialized: false
    readonly property bool overviewAvailable: provider.length === 0 && providers.length > 1
    readonly property bool overviewSelected: overviewAvailable && selectedProviderIndex < 0
    readonly property var selectedProviderData: providers.length > 0 && selectedProviderIndex >= 0
        ? providers[Math.min(selectedProviderIndex, providers.length - 1)]
        : null

    onCommandSourceChanged: Qt.callLater(refreshNow)
    onProvidersChanged: {
        if (providers.length === 0) {
            selectedProviderIndex = 0
            selectionInitialized = false
            return
        }
        if (!selectionInitialized) {
            selectedProviderIndex = overviewAvailable ? -1 : 0
            selectionInitialized = true
            return
        }
        if (!overviewAvailable && selectedProviderIndex < 0) {
            selectedProviderIndex = 0
        }
        if (selectedProviderIndex >= providers.length) {
            selectedProviderIndex = Math.max(0, providers.length - 1)
        }
    }

    Component.onCompleted: refreshNow()

    function buildCommand() {
        if (commandPath.length === 0) {
            return ""
        }

        var parts = [
            shellQuote(commandPath),
            "usage",
            "--format",
            "json",
            "--json-only"
        ]

        if (provider.length > 0) {
            parts.push("--provider")
            parts.push(shellQuote(provider))
        }

        if (source.length > 0) {
            parts.push("--source")
            parts.push(shellQuote(source))
        }

        if (includeStatus) {
            parts.push("--status")
        }

        return parts.join(" ")
    }

    function buildProviderConfigCommand() {
        if (commandPath.length === 0) {
            return ""
        }

        return [
            shellQuote(commandPath),
            "config",
            "providers",
            "--format",
            "json",
            "--json-only"
        ].join(" ")
    }

    function buildProviderUsageCommand(providerID, codexCliFallback) {
        var parts = [
            shellQuote(commandPath),
            "usage",
            "--provider",
            shellQuote(providerCliArgument(providerID)),
            "--format",
            "json",
            "--json-only"
        ]

        var effectiveSource = source
        if (codexCliFallback && source.length === 0 && providerKey(providerID) === "codex") {
            effectiveSource = "cli"
        }

        if (effectiveSource.length > 0) {
            parts.push("--source")
            parts.push(shellQuote(effectiveSource))
        }

        if (includeStatus) {
            parts.push("--status")
        }

        return parts.join(" ")
    }

    function buildCostCommand() {
        if (commandPath.length === 0) {
            return ""
        }

        var parts = [
            shellQuote(commandPath),
            "cost",
            "--format",
            "json",
            "--json-only"
        ]

        if (provider.length > 0) {
            parts.push("--provider")
            parts.push(shellQuote(provider))
        }

        return parts.join(" ")
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'"
    }

    function refreshNow() {
        disconnectUsageCommands()

        if (commandSource.length === 0) {
            errorText = i18n("Set the codexbar command path in widget settings.")
            return
        }

        loading = true
        errorText = ""
        providerFallbackActive = false
        if (canUseProviderFallback()) {
            startProviderFallback()
            refreshCost()
            return
        }
        connectedCommandSource = commandSource
        usageSource.connectSource(connectedCommandSource)
        refreshCost()
    }

    function disconnectUsageCommands() {
        if (connectedCommandSource.length > 0) {
            usageSource.disconnectSource(connectedCommandSource)
            connectedCommandSource = ""
        }
        if (connectedProviderConfigCommandSource.length > 0) {
            usageSource.disconnectSource(connectedProviderConfigCommandSource)
            connectedProviderConfigCommandSource = ""
        }
        for (var command in pendingProviderCommands) {
            usageSource.disconnectSource(command)
        }
        pendingProviderCommands = ({})
        fallbackProviderOrder = []
        fallbackProviderResults = ({})
        fallbackProviderSeen = ({})
        pendingProviderCount = 0
    }

    function refreshCost() {
        if (connectedCostCommandSource.length > 0) {
            usageSource.disconnectSource(connectedCostCommandSource)
            connectedCostCommandSource = ""
        }

        if (costCommandSource.length === 0) {
            tokenCosts = ({})
            costErrorText = ""
            return
        }

        costErrorText = ""
        connectedCostCommandSource = costCommandSource
        usageSource.connectSource(connectedCostCommandSource)
    }

    function parseOutput(stdoutText, stderrText) {
        var trimmed = stdoutText.trim()
        if (trimmed.length === 0) {
            if (canUseProviderFallback()) {
                startProviderFallback()
                return
            }
            providers = []
            errorText = stderrText.trim().length > 0 ? stderrText.trim() : i18n("codexbar did not return JSON.")
            loading = false
            return
        }

        var payload
        try {
            payload = JSON.parse(trimmed)
        } catch (error) {
            providers = []
            errorText = i18n("Could not parse codexbar JSON: %1", error.message)
            loading = false
            return
        }

        var items = Array.isArray(payload) ? payload : [payload]
        var nextProviders = []
        for (var i = 0; i < items.length; i++) {
            if (items[i]) {
                nextProviders.push(normalizeProvider(items[i]))
            }
        }

        providers = nextProviders
        errorText = nextProviders.length === 0 ? stderrText.trim() : ""
        lastUpdatedText = i18n("Updated %1", Qt.formatDateTime(new Date(), "hh:mm"))
        loading = false
    }

    function canUseProviderFallback() {
        return source.length === 0
    }

    function startProviderFallback() {
        providerFallbackActive = true
        if (connectedCommandSource.length > 0) {
            usageSource.disconnectSource(connectedCommandSource)
            connectedCommandSource = ""
        }
        if (provider.length > 0) {
            startProviderFallbackForProviders([providerKey(provider)])
            return
        }

        if (providerConfigCommandSource.length === 0) {
            providers = []
            errorText = i18n("codexbar did not return JSON.")
            loading = false
            return
        }

        connectedProviderConfigCommandSource = providerConfigCommandSource
        usageSource.connectSource(connectedProviderConfigCommandSource)
    }

    function parseProviderConfigOutput(stdoutText, stderrText) {
        var trimmed = stdoutText.trim()
        if (trimmed.length === 0) {
            providers = []
            errorText = stderrText.trim().length > 0 ? stderrText.trim() : i18n("Could not load CodexBar provider configuration.")
            loading = false
            return
        }

        var payload
        try {
            payload = JSON.parse(trimmed)
        } catch (error) {
            providers = []
            errorText = i18n("Could not parse CodexBar provider configuration: %1", error.message)
            loading = false
            return
        }

        var providerIDs = []
        var displayNames = ({})
        var items = Array.isArray(payload) ? payload : []
        for (var i = 0; i < items.length; i++) {
            if (items[i] && items[i].provider) {
                var providerID = providerKey(items[i].provider)
                if (items[i].displayName && String(items[i].displayName).trim().length > 0) {
                    displayNames[providerID] = String(items[i].displayName).trim()
                }
                if (items[i].enabled === true) {
                    providerIDs.push(providerID)
                }
            }
        }

        providerDisplayNames = displayNames
        startProviderFallbackForProviders(providerIDs)
    }

    function startProviderFallbackForProviders(providerIDs) {
        for (var existingCommand in pendingProviderCommands) {
            usageSource.disconnectSource(existingCommand)
        }
        pendingProviderCommands = ({})
        fallbackProviderOrder = []
        fallbackProviderResults = ({})
        fallbackProviderSeen = ({})
        pendingProviderCount = 0

        var commands = ({})
        var commandList = []
        for (var i = 0; i < providerIDs.length; i++) {
            var providerID = providerKey(providerIDs[i])
            var command = buildProviderUsageCommand(providerID, true)
            if (commands[command]) {
                continue
            }
            commands[command] = providerID
            commandList.push(command)
            fallbackProviderOrder.push(providerID)
            pendingProviderCount++
        }

        pendingProviderCommands = commands
        for (var j = 0; j < commandList.length; j++) {
            usageSource.connectSource(commandList[j])
        }
        if (pendingProviderCount === 0) {
            providers = []
            errorText = i18n("No enabled CodexBar providers.")
            loading = false
        }
    }

    function parseProviderFallbackOutput(sourceName, stdoutText, stderrText) {
        var providerID = pendingProviderCommands[sourceName] || ""
        if (providerID.length === 0) {
            return
        }
        if (fallbackProviderSeen[providerID]) {
            return
        }
        var seen = copyObject(fallbackProviderSeen)
        seen[providerID] = true
        fallbackProviderSeen = seen

        var normalizedItems = []
        var trimmed = stdoutText.trim()
        if (trimmed.length === 0) {
            normalizedItems.push(normalizeProvider(providerErrorPayload(
                providerID,
                stderrText.trim().length > 0 ? stderrText.trim() : i18n("codexbar did not return JSON."))))
        } else {
            var payload
            try {
                payload = JSON.parse(trimmed)
                var items = Array.isArray(payload) ? payload : [payload]
                for (var i = 0; i < items.length; i++) {
                    if (items[i]) {
                        if (!items[i].provider) {
                            items[i].provider = providerID
                        }
                        normalizedItems.push(normalizeProvider(items[i]))
                    }
                }
            } catch (error) {
                normalizedItems.push(normalizeProvider(providerErrorPayload(
                    providerID,
                    i18n("Could not parse codexbar JSON: %1", error.message))))
            }
        }

        var results = copyObject(fallbackProviderResults)
        results[providerID] = normalizedItems
        fallbackProviderResults = results
        pendingProviderCount = Math.max(0, pendingProviderCount - 1)

        if (pendingProviderCount === 0) {
            finishProviderFallback()
        }
    }

    function finishProviderFallback() {
        var nextProviders = []
        for (var i = 0; i < fallbackProviderOrder.length; i++) {
            var providerID = fallbackProviderOrder[i]
            var items = fallbackProviderResults[providerID] || []
            for (var j = 0; j < items.length; j++) {
                nextProviders.push(items[j])
            }
        }

        providers = nextProviders
        errorText = nextProviders.length === 0 ? i18n("codexbar did not return JSON.") : ""
        lastUpdatedText = i18n("Updated %1", Qt.formatDateTime(new Date(), "hh:mm"))
        loading = false
        fallbackProviderSeen = ({})
        pendingProviderCount = fallbackProviderOrder.length
        applyTokenCosts()
    }

    function providerErrorPayload(providerID, message) {
        return {
            provider: providerID,
            source: source.length > 0 ? source : "auto",
            error: {
                code: 1,
                kind: "provider",
                message: message
            }
        }
    }

    function parseCostOutput(stdoutText, stderrText) {
        var trimmed = stdoutText.trim()
        if (trimmed.length === 0) {
            tokenCosts = ({})
            costErrorText = stderrText.trim()
            applyTokenCosts()
            return
        }

        var payload
        try {
            payload = JSON.parse(trimmed)
        } catch (error) {
            tokenCosts = ({})
            costErrorText = i18n("Could not parse codexbar cost JSON: %1", error.message)
            applyTokenCosts()
            return
        }

        var items = Array.isArray(payload) ? payload : [payload]
        var nextCosts = ({})
        for (var i = 0; i < items.length; i++) {
            var cost = normalizeTokenCost(items[i])
            if (cost && cost.provider.length > 0) {
                nextCosts[cost.provider] = cost
            }
        }

        tokenCosts = nextCosts
        costErrorText = ""
        applyTokenCosts()
    }

    function normalizeTokenCost(item) {
        if (!item || !item.provider) {
            return null
        }

        var providerID = providerKey(item.provider)
        var currency = item.currencyCode || "USD"
        var windowLabel = item.historyLabel || (item.historyDays === 1 ? i18n("Today") : i18n("Last 30 days"))
        return {
            provider: providerID,
            title: i18n("Cost"),
            sessionLine: costLine(i18n("Today"), item.sessionCostUSD, item.sessionTokens, currency),
            monthLine: costLine(windowLabel, item.last30DaysCostUSD, item.last30DaysTokens, currency),
            hintLine: tokenCostHint(providerID)
        }
    }

    function applyTokenCosts() {
        if (!providers || providers.length === 0) {
            return
        }

        var nextProviders = []
        for (var i = 0; i < providers.length; i++) {
            var item = copyObject(providers[i])
            item.tokenCost = tokenCosts[item.provider] || null
            nextProviders.push(item)
        }
        providers = nextProviders
    }

    function normalizeProvider(item) {
        var usage = item.usage || ({})
        var pace = item.pace || ({})
        var rows = []
        var providerID = providerKey(item.provider || "unknown")

        addWindow(rows, rateWindowLabel(providerID, "primary"), usage.primary, pace.primary, true, "primary")
        addWindow(rows, rateWindowLabel(providerID, "secondary"), usage.secondary, pace.secondary, true, "secondary")
        addWindow(rows, rateWindowLabel(providerID, "tertiary"), usage.tertiary, null, true, "tertiary")

        var extras = usage.extraRateWindows || []
        for (var i = 0; i < extras.length; i++) {
            var extra = extras[i]
            if (extra && extra.window) {
                addWindow(rows, extra.title || extra.id || i18n("Extra"), extra.window, null, extra.usageKnown !== false, "extra")
            }
        }

        var identity = usage.identity || ({})
        var error = item.error || null
        var status = item.status || null
        var credits = item.credits || null
        var placeholder = providerPlaceholder(providerID, rows, usage, item, error)
        var displayName = item.displayName || item.title || providerDisplayNames[providerID] || ""

        return {
            provider: providerID,
            title: providerTitle(providerID, displayName),
            source: item.source || "",
            version: item.version || "",
            account: item.account || identity.accountEmail || usage.accountEmail || "",
            organization: identity.accountOrganization || usage.accountOrganization || "",
            loginMethod: identity.loginMethod || usage.loginMethod || "",
            rows: rows,
            providerCost: providerCostSection(providerID, usage.providerCost),
            resetCredits: resetCreditsSection(providerID, usage.codexResetCredits),
            tokenCost: tokenCosts[providerID] || null,
            planText: planText(providerID, usage, item),
            dashboardUrl: providerDashboardUrl(providerID),
            statusUrl: status && status.url ? status.url : providerStatusUrl(providerID),
            changelogUrl: providerChangelogUrl(providerID),
            credits: credits && credits.remaining !== null && credits.remaining !== undefined && isFinite(Number(credits.remaining))
                ? Number(credits.remaining)
                : null,
            status: status ? statusText(status) : "",
            error: error && error.message ? error.message : "",
            placeholder: placeholder,
            updatedAt: usage.updatedAt || (credits ? credits.updatedAt : "")
        }
    }

    function providerPlaceholder(providerID, rows, usage, item, error) {
        if (rows && rows.length > 0) {
            return ""
        }

        var message = error && error.message ? String(error.message).trim() : ""
        if (message.length > 0 && message !== "Found sessions, but no rate limit events yet.") {
            return ""
        }

        if (rateLimitsUnavailable(providerID, usage, item)) {
            return i18n("Limits not available")
        }

        return i18n("No usage yet")
    }

    function rateLimitsUnavailable(providerID, usage, item) {
        var key = providerKey(providerID)
        if (key !== "antigravity" && key !== "doubao" && key !== "codex") {
            return false
        }

        var identity = usage && usage.identity ? usage.identity : ({})
        var hasIdentity = (item && item.account && item.account.length > 0)
            || (identity.accountEmail && identity.accountEmail.length > 0)
            || (identity.accountOrganization && identity.accountOrganization.length > 0)
            || (identity.loginMethod && identity.loginMethod.length > 0)
        if (!hasIdentity) {
            return false
        }

        return !usage.primary && !usage.secondary && !usage.tertiary
    }

    function addWindow(rows, label, window, pace, usageKnown, lane) {
        if (!window) {
            return
        }

        var known = usageKnown !== false
        var used = Number(window.usedPercent)
        var hasPercent = known && isFinite(used)
        var paceValue = pace && isFinite(Number(pace.expectedUsedPercent))
            ? clamp(Number(pace.expectedUsedPercent), 0, 100)
            : -1
        rows.push({
            lane: lane || "",
            label: label,
            hasPercent: hasPercent,
            usedPercent: hasPercent ? clamp(used, 0, 100) : 0,
            leftPercent: hasPercent ? clamp(100 - used, 0, 100) : 0,
            pacePercent: paceValue,
            paceOnTop: !pace || pace.willLastToReset !== false,
            reset: resetText(window),
            pace: pace && pace.summary ? pace.summary : ""
        })
    }

    function rateWindowLabel(providerID, lane) {
        var key = providerKey(providerID)
        if (lane === "primary") {
            switch (key) {
            case "alibaba":
            case "opencode":
            case "opencodego":
                return i18n("5-hour")
            case "amp":
                return i18n("Amp Free")
            case "antigravity":
                return i18n("Gemini Models")
            case "azureopenai":
                return i18n("Status")
            case "bedrock":
                return i18n("Budget")
            case "commandcode":
            case "manus":
                return i18n("Monthly credits")
            case "copilot":
                return i18n("Premium")
            case "cursor":
                return i18n("Total")
            case "factory":
                return i18n("Standard")
            case "doubao":
            case "grok":
            case "groq":
            case "vertexai":
                return i18n("Requests")
            case "gemini":
                return i18n("Pro")
            case "kilo":
            case "kiro":
            case "mimo":
            case "warp":
            case "abacus":
                return i18n("Credits")
            case "kimi":
                return i18n("Weekly")
            case "minimax":
                return i18n("Prompts")
            case "openai":
                return i18n("Spend")
            case "openrouter":
                return i18n("API key limit")
            case "poe":
                return i18n("Points")
            case "zed":
                return i18n("Edit predictions")
            default:
                return i18n("Session")
            }
        }
        if (lane === "secondary") {
            switch (key) {
            case "antigravity":
                return i18n("Claude and GPT")
            case "amp":
                return i18n("Balance")
            case "azureopenai":
                return i18n("Deployment")
            case "bedrock":
                return i18n("Cost")
            case "copilot":
                return i18n("Chat")
            case "cursor":
                return i18n("Auto")
            case "factory":
                return i18n("Premium")
            case "doubao":
            case "kimi":
                return i18n("Rate limit")
            case "gemini":
                return i18n("Flash")
            case "grok":
                return i18n("On-demand")
            case "groq":
            case "vertexai":
                return i18n("Tokens")
            case "kilo":
                return i18n("Kilo Pass")
            case "kiro":
                return i18n("Bonus")
            case "mimo":
            case "minimax":
                return i18n("Window")
            case "openai":
                return i18n("Requests")
            case "warp":
                return i18n("Add-on credits")
            case "zed":
                return i18n("Billing cycle")
            default:
                return i18n("Weekly")
            }
        }
        if (lane === "tertiary") {
            if (key === "alibaba" || key === "opencodego") {
                return i18n("Monthly")
            }
            if (key === "claude") {
                return i18n("Sonnet")
            }
            if (key === "cursor") {
                return i18n("API")
            }
            if (key === "gemini") {
                return i18n("Flash Lite")
            }
            return i18n("Opus")
        }
        return i18n("Usage")
    }

    function providerCostSection(providerID, cost) {
        var key = providerKey(providerID)
        if (key === "manus" || key === "synthetic") {
            return null
        }

        if (!cost) {
            return null
        }

        var used = Number(cost.used)
        var limit = Number(cost.limit)
        var currency = cost.currencyCode || "USD"
        var period = cost.period || i18n("This month")
        var hasUsed = isFinite(used)
        var hasLimit = isFinite(limit) && limit > 0
        if (!hasUsed) {
            return null
        }

        if (key === "factory" && period === "Extra usage balance") {
            return {
                title: i18n("Extra usage"),
                percentUsed: -1,
                spendLine: i18n("Balance: %1", amountString(used, currency)),
                percentLine: "",
                personalSpendLine: ""
            }
        }

        if (key === "opencodego" && period === "Zen balance") {
            return {
                title: i18n("Zen balance"),
                percentUsed: -1,
                spendLine: i18n("Balance: %1", amountString(used, currency)),
                percentLine: "",
                personalSpendLine: ""
            }
        }

        if (key === "minimax" && period === "MiniMax points balance") {
            return {
                title: i18n("Credits"),
                percentUsed: -1,
                spendLine: i18n("Balance: %1", Math.round(used)),
                percentLine: "",
                personalSpendLine: ""
            }
        }

        if (hasLimit) {
            var percent = clamp((used / limit) * 100, 0, 100)
            return {
                title: currency === "Quota" ? i18n("Quota usage") : i18n("Extra usage"),
                percentUsed: percent,
                spendLine: i18n("%1: %2 / %3", localizedPeriod(period), amountString(used, currency), amountString(limit, currency)),
                percentLine: i18n("%1% used", Math.round(percent)),
                personalSpendLine: cost.personalUsed && Number(cost.personalUsed) > 0
                    ? i18n("Your spend: %1", amountString(Number(cost.personalUsed), currency))
                    : ""
            }
        }

        if (key === "litellm") {
            return null
        }

        return {
            title: key === "openai" || key === "claude"
                ? i18n("API spend")
                : i18n("Extra usage"),
            percentUsed: -1,
            spendLine: i18n("%1: %2", localizedPeriod(period), amountString(used, currency)),
            percentLine: "",
            personalSpendLine: ""
        }
    }

    function resetCreditsSection(providerID, resetCredits) {
        if (providerKey(providerID) !== "codex" || !resetCredits) {
            return null
        }

        var count = Number(resetCredits.availableCount)
        if (!isFinite(count) || count <= 0) {
            return null
        }

        return {
            title: i18n("Reset credits"),
            line: i18n("%1 available", Math.round(count))
        }
    }

    function resetText(window) {
        if (window.resetDescription && window.resetDescription.length > 0) {
            return window.resetDescription
        }

        if (!window.resetsAt) {
            return ""
        }

        var date = new Date(window.resetsAt)
        if (isNaN(date.getTime())) {
            return String(window.resetsAt)
        }

        return Qt.formatDateTime(date, "ddd HH:mm")
    }

    function statusText(status) {
        var indicator = String(status.indicator || "")
        var description = String(status.description || "").trim()
        if (indicator.length === 0 || indicator === "none") {
            return description
        }

        var labels = {
            "minor": i18n("Partial outage"),
            "major": i18n("Major outage"),
            "critical": i18n("Critical issue"),
            "maintenance": i18n("Maintenance"),
            "unknown": i18n("Status unknown")
        }
        var text = labels[indicator] || indicator
        return description.length > 0 ? text + ": " + description : text
    }

    function planText(providerID, usage, item) {
        var identity = usage.identity || ({})
        var method = identity.loginMethod || usage.loginMethod || ""
        if (providerKey(providerID) === "codex" && method.length > 0) {
            return capitalize(method)
        }
        return ""
    }

    function providerKey(value) {
        var key = String(value || "codex").toLowerCase()
        var aliases = {
            "abacusai": "abacus",
            "agy": "antigravity",
            "alibaba-coding-plan": "alibaba",
            "alibaba-token-plan": "alibabatokenplan",
            "aws-bedrock": "bedrock",
            "droid": "factory",
            "gemini-cli": "gemini",
            "groqcloud": "groq",
            "kimi-k2": "kimik2",
            "vertex": "vertexai"
        }
        return aliases[key] || key
    }

    function providerCliArgument(value) {
        switch (providerKey(value)) {
        case "abacus":
            return "abacusai"
        case "alibaba":
            return "alibaba-coding-plan"
        case "alibabatokenplan":
            return "alibaba-token-plan"
        case "azureopenai":
            return "azure-openai"
        case "bedrock":
            return "bedrock"
        case "groq":
            return "groqcloud"
        default:
            return providerKey(value)
        }
    }

    function providerTitle(value, displayName) {
        var key = providerKey(value)
        var preferred = String(displayName || "").trim()
        if (preferred.length > 0) {
            return preferred
        }

        var names = {
            "aws-bedrock": "AWS Bedrock",
            "abacus": "Abacus AI",
            "abacusai": "Abacus AI",
            "alibaba-coding-plan": "Alibaba Coding",
            "alibaba-token-plan": "Alibaba Token",
            "alibaba": "Alibaba",
            "alibabatokenplan": "Alibaba Token Plan",
            "azureopenai": "Azure OpenAI",
            "bedrock": "AWS Bedrock",
            "antigravity": "Antigravity",
            "augment": "Augment",
            "chutes": "Chutes",
            "claude": "Claude",
            "codebuff": "Codebuff",
            "commandcode": "Command Code",
            "codex": "Codex",
            "copilot": "Copilot",
            "crof": "Crof",
            "cursor": "Cursor",
            "deepgram": "Deepgram",
            "deepseek": "DeepSeek",
            "devin": "Devin",
            "doubao": "Doubao",
            "factory": "Droid",
            "gemini": "Gemini",
            "grok": "Grok",
            "groq": "Groq",
            "groqcloud": "GroqCloud",
            "jetbrains": "JetBrains AI",
            "kilo": "Kilo",
            "kimi-k2": "Kimi K2 (unofficial)",
            "kimik2": "Kimi K2 (unofficial)",
            "kiro": "Kiro",
            "litellm": "LiteLLM",
            "llmproxy": "LLM Proxy",
            "manus": "Manus",
            "mistral": "Mistral",
            "mimo": "Xiaomi MiMo",
            "moonshot": "Moonshot / Kimi API",
            "ollama": "Ollama",
            "openai": "OpenAI",
            "opencode": "OpenCode",
            "opencodego": "OpenCode Go",
            "openrouter": "OpenRouter",
            "perplexity": "Perplexity",
            "synthetic": "Synthetic",
            "t3chat": "T3 Chat",
            "venice": "Venice",
            "vertexai": "Vertex AI",
            "warp": "Warp",
            "windsurf": "Windsurf",
            "zai": "z.ai"
        }

        if (names[key]) {
            return names[key]
        }

        var words = String(key).replace(/[_-]/g, " ").split(" ")
        for (var i = 0; i < words.length; i++) {
            if (words[i].length > 0) {
                words[i] = words[i].charAt(0).toUpperCase() + words[i].slice(1)
            }
        }
        return words.join(" ")
    }

    function providerIconSource(value) {
        var key = providerKey(value)
        var aliases = {
            "aws-bedrock": "bedrock",
            "gemini": "gemini-white.png",
            "kimi-k2": "kimik2"
        }
        key = aliases[key] || key
        var fileName = key.indexOf(".") === -1 ? key + ".svg" : key
        return Qt.resolvedUrl("../icons/providers/" + fileName)
    }

    function providerIconIsMask(value) {
        return true
    }

    function providerColor(value) {
        switch (providerKey(value)) {
        case "abacus":
            return Qt.rgba(56 / 255, 189 / 255, 248 / 255, 1)
        case "alibaba":
        case "alibabatokenplan":
            return Qt.rgba(1, 106 / 255, 0, 1)
        case "amp":
            return Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)
        case "codex":
            return Qt.rgba(73 / 255, 163 / 255, 176 / 255, 1)
        case "openai":
            return Qt.rgba(15 / 255, 130 / 255, 110 / 255, 1)
        case "claude":
            return Qt.rgba(204 / 255, 124 / 255, 94 / 255, 1)
        case "gemini":
            return Qt.rgba(171 / 255, 135 / 255, 234 / 255, 1)
        case "antigravity":
            return Qt.rgba(96 / 255, 186 / 255, 126 / 255, 1)
        case "cursor":
            return Qt.rgba(0, 191 / 255, 165 / 255, 1)
        case "copilot":
            return Qt.rgba(168 / 255, 85 / 255, 247 / 255, 1)
        case "bedrock":
            return Qt.rgba(1, 0.6, 0, 1)
        case "codebuff":
            return Qt.rgba(68 / 255, 1, 0, 1)
        case "commandcode":
            return Qt.rgba(0, 0, 0, 1)
        case "crof":
            return Qt.rgba(46 / 255, 171 / 255, 148 / 255, 1)
        case "deepgram":
            return Qt.rgba(100 / 255, 103 / 255, 242 / 255, 1)
        case "deepseek":
            return Qt.rgba(82 / 255, 125 / 255, 240 / 255, 1)
        case "devin":
            return Qt.rgba(70 / 255, 180 / 255, 130 / 255, 1)
        case "doubao":
            return Qt.rgba(51 / 255, 112 / 255, 1, 1)
        case "elevenlabs":
            return Qt.rgba(235 / 255, 235 / 255, 230 / 255, 1)
        case "factory":
            return Qt.rgba(1, 107 / 255, 53 / 255, 1)
        case "grok":
            return Qt.rgba(16 / 255, 163 / 255, 127 / 255, 1)
        case "groq":
            return Qt.rgba(245 / 255, 104 / 255, 68 / 255, 1)
        case "jetbrains":
            return Qt.rgba(1, 51 / 255, 153 / 255, 1)
        case "kilo":
            return Qt.rgba(242 / 255, 112 / 255, 39 / 255, 1)
        case "kimi":
        case "minimax":
            return Qt.rgba(254 / 255, 96 / 255, 60 / 255, 1)
        case "kimik2":
            return Qt.rgba(76 / 255, 0, 1, 1)
        case "kiro":
            return Qt.rgba(1, 153 / 255, 0, 1)
        case "litellm":
            return Qt.rgba(76 / 255, 137 / 255, 240 / 255, 1)
        case "llmproxy":
            return Qt.rgba(36 / 255, 180 / 255, 126 / 255, 1)
        case "manus":
            return Qt.rgba(52 / 255, 50 / 255, 45 / 255, 1)
        case "mimo":
            return Qt.rgba(1, 105 / 255, 0, 1)
        case "mistral":
            return Qt.rgba(1, 80 / 255, 15 / 255, 1)
        case "moonshot":
            return Qt.rgba(32 / 255, 93 / 255, 235 / 255, 1)
        case "ollama":
            return Qt.rgba(136 / 255, 136 / 255, 136 / 255, 1)
        case "opencode":
        case "opencodego":
            return Qt.rgba(59 / 255, 130 / 255, 246 / 255, 1)
        case "openrouter":
            return Qt.rgba(100 / 255, 103 / 255, 242 / 255, 1)
        case "perplexity":
            return Qt.rgba(32 / 255, 178 / 255, 170 / 255, 1)
        case "poe":
            return Qt.rgba(38 / 255, 173 / 255, 97 / 255, 1)
        case "stepfun":
            return Qt.rgba(0.13, 0.59, 0.95, 1)
        case "t3chat":
            return Qt.rgba(245 / 255, 102 / 255, 71 / 255, 1)
        case "venice":
            return Qt.rgba(0.2, 0.6, 1, 1)
        case "vertexai":
            return Qt.rgba(66 / 255, 133 / 255, 244 / 255, 1)
        case "warp":
            return Qt.rgba(147 / 255, 139 / 255, 180 / 255, 1)
        case "windsurf":
            return Qt.rgba(52 / 255, 232 / 255, 187 / 255, 1)
        case "zed":
            return Qt.rgba(8 / 255, 78 / 255, 1, 1)
        case "zai":
            return Qt.rgba(232 / 255, 90 / 255, 106 / 255, 1)
        default:
            return Kirigami.Theme.highlightColor
        }
    }

    function providerDashboardUrl(providerID) {
        switch (providerKey(providerID)) {
        case "abacus":
            return "https://apps.abacus.ai/chatllm/admin/compute-points-usage"
        case "alibaba":
            return "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan"
        case "alibabatokenplan":
            return "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan"
        case "amp":
            return "https://ampcode.com/settings#billing"
        case "augment":
            return "https://app.augmentcode.com/account/subscription"
        case "azureopenai":
            return "https://ai.azure.com"
        case "bedrock":
            return "https://console.aws.amazon.com/bedrock"
        case "chutes":
            return "https://chutes.ai"
        case "codebuff":
            return "https://www.codebuff.com/usage"
        case "commandcode":
            return "https://commandcode.ai/studio"
        case "codex":
            return "https://chatgpt.com/codex/settings/usage"
        case "claude":
            return "https://claude.ai/settings/usage"
        case "copilot":
            return "https://github.com/settings/copilot"
        case "cursor":
            return "https://cursor.com/dashboard?tab=usage"
        case "deepgram":
            return "https://console.deepgram.com/project/"
        case "deepseek":
            return "https://platform.deepseek.com/usage"
        case "devin":
            return "https://app.devin.ai"
        case "doubao":
            return "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe"
        case "elevenlabs":
            return "https://elevenlabs.io/app/developers/usage"
        case "factory":
            return "https://app.factory.ai/settings/billing"
        case "gemini":
            return "https://gemini.google.com"
        case "grok":
            return "https://grok.com/?_s=usage"
        case "groq":
            return "https://console.groq.com/dashboard/metrics"
        case "kilo":
            return "https://app.kilo.ai/usage"
        case "kimi":
            return "https://www.kimi.com/code/console"
        case "kiro":
            return "https://app.kiro.dev/account/usage"
        case "manus":
            return "https://manus.im"
        case "mimo":
            return "https://platform.xiaomimimo.com/#/console/balance"
        case "mistral":
            return "https://admin.mistral.ai/organization/usage"
        case "moonshot":
            return "https://platform.moonshot.ai/console/account"
        case "minimax":
            return "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3"
        case "ollama":
            return "https://ollama.com/settings"
        case "openai":
            return "https://platform.openai.com/usage"
        case "opencode":
        case "opencodego":
            return "https://opencode.ai"
        case "openrouter":
            return "https://openrouter.ai/settings/credits"
        case "perplexity":
            return "https://www.perplexity.ai/account/usage"
        case "poe":
            return "https://poe.com/api/keys"
        case "stepfun":
            return "https://platform.stepfun.com/plan-usage"
        case "t3chat":
            return "https://t3.chat/settings/customization"
        case "venice":
            return "https://venice.ai/settings/api"
        case "vertexai":
            return "https://console.cloud.google.com/vertex-ai"
        case "warp":
            return "https://docs.warp.dev/reference/cli/api-keys"
        case "windsurf":
            return "https://windsurf.com/subscription/usage"
        case "zai":
            return "https://z.ai/manage-apikey/coding-plan/personal/my-plan"
        default:
            return ""
        }
    }

    function providerStatusUrl(providerID) {
        switch (providerKey(providerID)) {
        case "alibaba":
        case "alibabatokenplan":
            return "https://status.aliyun.com"
        case "antigravity":
        case "gemini":
            return "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history"
        case "azureopenai":
            return "https://azure.status.microsoft/en-us/status"
        case "bedrock":
        case "kiro":
            return "https://health.aws.amazon.com/health/status"
        case "codex":
        case "openai":
            return "https://status.openai.com/"
        case "claude":
            return "https://status.claude.com/"
        case "copilot":
            return "https://www.githubstatus.com/"
        case "cursor":
            return "https://status.cursor.com"
        case "deepgram":
            return "https://status.deepgram.com"
        case "deepseek":
            return "https://status.deepseek.com"
        case "elevenlabs":
            return "https://status.elevenlabs.io"
        case "factory":
            return "https://status.factory.ai"
        case "grok":
            return "https://status.x.ai"
        case "groq":
            return "https://status.groq.com"
        case "openrouter":
            return "https://status.openrouter.ai/"
        case "perplexity":
            return "https://status.perplexity.com/"
        case "vertexai":
            return "https://status.cloud.google.com"
        default:
            return ""
        }
    }

    function providerChangelogUrl(providerID) {
        switch (providerKey(providerID)) {
        case "codex":
            return "https://github.com/openai/codex/releases"
        case "claude":
            return "https://github.com/anthropics/claude-code/releases"
        case "gemini":
            return "https://github.com/google-gemini/gemini-cli/releases"
        case "grok":
            return "https://x.ai/news"
        default:
            return ""
        }
    }

    function actionRows(item) {
        if (!item) {
            return []
        }

        var rows = []
        var accountAction = providerAccountAction(item)
        if (accountAction) {
            rows.push(accountAction)
        }

        if (item.dashboardUrl && item.dashboardUrl.length > 0) {
            rows.push({ title: i18n("Usage Dashboard"), icon: "view-statistics", action: "dashboard", enabled: true })
        }
        if (item.statusUrl && item.statusUrl.length > 0) {
            rows.push({ title: i18n("Status Page"), icon: "network-connect", action: "status", enabled: true })
        }
        if (showProviderChangelogs && item.changelogUrl && item.changelogUrl.length > 0) {
            rows.push({ title: i18n("Changelog"), icon: "view-list-details", action: "changelog", enabled: true })
        }

        rows.push({ title: i18n("Refresh"), icon: "view-refresh", action: "refresh", enabled: true })
        rows.push({ title: i18n("Settings..."), icon: "configure", action: "settings", enabled: true })
        rows.push({ title: i18n("About CodexBar"), icon: "help-about", action: "about", enabled: true })
        return rows
    }

    function providerAccountAction(item) {
        var title = item.account && item.account.length > 0 ? i18n("Switch Account...") : i18n("Add Account...")
        switch (providerKey(item.provider)) {
        case "devin":
            return { title: i18n("Open Devin..."), icon: "internet-services", action: "account-url", url: "https://app.devin.ai/settings/usage", enabled: true }
        case "factory":
            return { title: i18n("Open Droid in Browser..."), icon: "internet-services", action: "account-url", url: "https://app.factory.ai", enabled: true }
        case "manus":
            return { title: title, icon: "internet-services", action: "account-url", url: "https://manus.im", enabled: true }
        case "mimo":
            return { title: title, icon: "internet-services", action: "account-url", url: "https://platform.xiaomimimo.com/api/v1/genLoginUrl?currentPath=%2F%23%2Fconsole%2Fbalance", enabled: true }
        case "perplexity":
            return { title: title, icon: "internet-services", action: "account-url", url: "https://www.perplexity.ai/", enabled: true }
        default:
            return null
        }
    }

    function performAction(actionRow) {
        var actionID = actionRow && actionRow.action ? actionRow.action : actionRow
        var item = selectedProviderData
        if (actionID === "dashboard" && item) {
            Qt.openUrlExternally(item.dashboardUrl)
        } else if (actionID === "status" && item) {
            Qt.openUrlExternally(item.statusUrl)
        } else if (actionID === "changelog" && item) {
            Qt.openUrlExternally(item.changelogUrl)
        } else if (actionID === "account-url" && actionRow && actionRow.url) {
            Qt.openUrlExternally(actionRow.url)
        } else if (actionID === "refresh") {
            root.refreshNow()
        } else if (actionID === "about") {
            Qt.openUrlExternally("https://github.com/steipete/CodexBar")
        } else if (actionID === "settings") {
            var action = Plasmoid.internalAction("configure")
            if (action) {
                action.trigger()
            }
        }
    }

    function withAlpha(color, alpha) {
        return Qt.rgba(color.r, color.g, color.b, alpha)
    }

    function contrastTextColor(color) {
        var luminance = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b)
        return luminance > 0.62 ? Qt.rgba(0.08, 0.08, 0.1, 1) : Qt.rgba(1, 1, 1, 1)
    }

    function copyObject(item) {
        var copy = ({})
        for (var key in item) {
            copy[key] = item[key]
        }
        return copy
    }

    function hasText(value) {
        return String(value || "").trim().length > 0
    }

    function hasAdditionalSections(item) {
        return item && (item.credits !== null || item.resetCredits || item.providerCost || item.tokenCost) ? true : false
    }

    function capitalize(value) {
        var text = String(value || "")
        if (text.length === 0) {
            return ""
        }
        return text.charAt(0).toUpperCase() + text.slice(1)
    }

    function localizedPeriod(value) {
        var text = String(value || "").trim()
        switch (text.toLowerCase()) {
        case "last 30 days":
            return i18n("Last 30 days")
        case "this month":
            return i18n("This month")
        case "today":
            return i18n("Today")
        default:
            return text
        }
    }

    function amountString(value, currency) {
        if (currency === "Quota") {
            return Math.round(value).toString()
        }
        var numeric = Number(value)
        var negative = numeric < 0
        var amount = Math.abs(numeric).toFixed(2)
        if (currency === "USD") {
            return negative ? "-$" + amount : "$" + amount
        }
        return (negative ? "-" : "") + currency + " " + amount
    }

    function costLine(label, cost, tokens, currency) {
        var costValue = isFinite(Number(cost)) ? amountString(Number(cost), currency) : "—"
        if (isFinite(Number(tokens))) {
            return i18n("%1: %2 · %3 tokens", label, costValue, tokenCountString(Number(tokens)))
        }
        return i18n("%1: %2", label, costValue)
    }

    function tokenCountString(tokens) {
        var value = Number(tokens)
        if (!isFinite(value)) {
            return "—"
        }
        var absValue = Math.abs(value)
        var sign = value < 0 ? "-" : ""
        if (absValue >= 1000000000) {
            return sign + scaledTokenCount(absValue / 1000000000) + "B"
        }
        if (absValue >= 1000000) {
            return sign + scaledTokenCount(absValue / 1000000) + "M"
        }
        if (absValue >= 1000) {
            return sign + scaledTokenCount(absValue / 1000) + "K"
        }
        return Math.round(value).toString()
    }

    function scaledTokenCount(value) {
        if (value >= 10) {
            return Number(value).toFixed(0)
        }
        var text = Number(value).toFixed(1)
        return text.replace(/\.0$/, "")
    }

    function tokenCostHint(providerID) {
        switch (providerKey(providerID)) {
        case "codex":
            return i18n("Estimated from local Codex logs for the selected account.")
        case "claude":
            return i18n("Estimated from local Claude logs.")
        default:
            return ""
        }
    }

    function firstUsageRow(item) {
        if (!item || !item.rows) {
            return null
        }
        for (var i = 0; i < item.rows.length; i++) {
            if (item.rows[i] && item.rows[i].hasPercent) {
                return item.rows[i]
            }
        }
        return null
    }

    function usageRowForLane(item, lane) {
        if (!item || !item.rows) {
            return null
        }
        for (var i = 0; i < item.rows.length; i++) {
            if (item.rows[i] && item.rows[i].lane === lane && item.rows[i].hasPercent) {
                return item.rows[i]
            }
        }
        return null
    }

    function switcherMetricRow(item) {
        if (!item || !item.rows || item.rows.length === 0) {
            return null
        }

        var key = providerKey(item.provider)
        var primary = usageRowForLane(item, "primary")
        var secondary = usageRowForLane(item, "secondary")
        if (key === "factory") {
            return secondary || primary || firstUsageRow(item)
        }
        if (key === "perplexity") {
            if (primary && primary.leftPercent > 0) {
                return primary
            }
            return secondary || usageRowForLane(item, "tertiary") || primary || firstUsageRow(item)
        }
        if (key === "cursor" && !usageBarsShowUsed && primary && primary.leftPercent <= 0
                && item.providerCost && item.providerCost.percentUsed >= 0) {
            var used = clamp(Number(item.providerCost.percentUsed), 0, 100)
            return {
                lane: "providerCost",
                label: i18n("Included plan"),
                hasPercent: true,
                usedPercent: used,
                leftPercent: clamp(100 - used, 0, 100),
                pacePercent: -1,
                paceOnTop: true,
                reset: "",
                pace: ""
            }
        }

        return primary || secondary || firstUsageRow(item)
    }

    function primaryUsedPercent(item) {
        var row = firstUsageRow(item)
        return row ? row.usedPercent : -1
    }

    function switcherPercent(item) {
        var row = switcherMetricRow(item)
        return row ? displayPercent(row) : -1
    }

    function isOverviewErrorOnly(item) {
        return item
            && item.error
            && item.error.length > 0
            && (!item.rows || item.rows.length === 0)
            && providerPlaceholderText(item).length === 0
            && item.credits === null
            && !item.resetCredits
            && !item.providerCost
            && !item.tokenCost
    }

    function overviewProviders() {
        var result = []
        if (!providers) {
            return result
        }
        for (var i = 0; i < providers.length; i++) {
            if (!isOverviewErrorOnly(providers[i])) {
                result.push(providers[i])
            }
        }
        return result
    }

    function providerIndex(item) {
        if (!item || !providers) {
            return 0
        }
        for (var i = 0; i < providers.length; i++) {
            if (providers[i] && providers[i].provider === item.provider) {
                return i
            }
        }
        return 0
    }

    function overviewPercent() {
        var items = overviewProviders()
        if (!items || items.length === 0) {
            return -1
        }

        var total = 0
        var count = 0
        for (var i = 0; i < items.length; i++) {
            var percent = switcherPercent(items[i])
            if (percent >= 0) {
                total += percent
                count++
            }
        }
        return count > 0 ? total / count : -1
    }

    function overviewDetailText(item) {
        if (!item) {
            return ""
        }
        if (item.account && item.account.length > 0) {
            return item.account
        }
        if (item.status && item.status.length > 0) {
            return item.status
        }
        var placeholder = providerPlaceholderText(item)
        if (placeholder.length > 0) {
            return placeholder
        }
        if (item.source && item.source.length > 0) {
            return item.source
        }
        return ""
    }

    function providerPlaceholderText(item) {
        if (!item || !item.placeholder || item.placeholder.length === 0) {
            return ""
        }
        if (item.provider === "codex" && item.tokenCost) {
            return ""
        }
        return item.placeholder
    }

    function displayPercent(row) {
        if (!row || !row.hasPercent) {
            return 0
        }
        return usageBarsShowUsed ? row.usedPercent : row.leftPercent
    }

    function paceMarkerPercent(row) {
        if (!row || row.pacePercent < 0) {
            return -1
        }
        return usageBarsShowUsed ? row.pacePercent : clamp(100 - row.pacePercent, 0, 100)
    }

    function percentSuffix() {
        return usageBarsShowUsed ? i18n("used") : i18n("left")
    }

    function resetLabel(value) {
        var text = String(value || "").trim()
        if (text.length === 0) {
            return ""
        }
        text = text
            .replace(/([A-Za-z])(\d)/g, "$1 $2")
            .replace(/(\d)([A-Za-z])/g, "$1 $2")
            .replace(/\)([A-Za-z])/g, ") $1")
            .replace(/(am|pm)\(/ig, "$1 (")
            .replace(/\s+/g, " ")
        if (/^resets\b/i.test(text)) {
            return text.replace(/^resets\s*/i, i18n("Resets "))
        }
        return i18n("Resets %1", text)
    }

    function clamp(value, minimum, maximum) {
        return Math.max(minimum, Math.min(maximum, value))
    }

    function primaryProvider() {
        return providers.length > 0 ? providers[0] : null
    }

    function compactProviders() {
        if (!providers || providers.length <= 1
                || Plasmoid.configuration.showMultiProviderInPanel !== true) {
            return []
        }

        var result = []
        for (var i = 0; i < providers.length && result.length < 4; i++) {
            if (switcherPercent(providers[i]) >= 0) {
                result.push(providers[i])
            }
        }
        return result
    }

    function compactText() {
        var item = primaryProvider()
        if (!item) {
            return loading ? i18n("Loading") : "CodexBar"
        }

        var parts = []
        if (Plasmoid.configuration.showProviderInPanel) {
            parts.push(item.title)
        }

        var percent = switcherPercent(item)
        if (Plasmoid.configuration.showPercentInPanel && percent >= 0) {
            parts.push(i18n("%1%", Math.round(percent)))
        }

        if (Plasmoid.configuration.showCreditsInPanel && item.credits !== null) {
            parts.push(i18n("%1cr", formatNumber(item.credits)))
        }

        return parts.join(" ")
    }

    function formatNumber(value) {
        if (Math.abs(value) >= 100) {
            return Math.round(value).toString()
        }
        return Number(value).toFixed(1)
    }

    Plasma5Support.DataSource {
        id: usageSource

        engine: "executable"
        interval: root.refreshIntervalSec * 1000

        onNewData: function(sourceName, data) {
            var stdoutText = data && data["stdout"] ? data["stdout"] : ""
            var stderrText = data && data["stderr"] ? data["stderr"] : ""

            if (sourceName === root.connectedCostCommandSource) {
                root.parseCostOutput(stdoutText, stderrText)
                return
            }

            if (sourceName === root.connectedProviderConfigCommandSource) {
                root.parseProviderConfigOutput(stdoutText, stderrText)
                return
            }

            if (root.pendingProviderCommands[sourceName]) {
                root.parseProviderFallbackOutput(sourceName, stdoutText, stderrText)
                return
            }

            if (sourceName === root.connectedCommandSource) {
                root.parseOutput(stdoutText, stderrText)
            }
        }
    }

    compactRepresentation: Item {
        id: compactRoot

        readonly property bool hasProviderMeters: root.compactProviders().length > 0
        readonly property string primaryText: root.compactText()
        readonly property bool showPrimaryIdentity: !hasProviderMeters || primaryText.length > 0
        readonly property int desiredWidth: Math.min(
            hasProviderMeters ? Kirigami.Units.gridUnit * 8.5 : Kirigami.Units.gridUnit * 8.5,
            Math.max(
                hasProviderMeters ? Kirigami.Units.gridUnit * 4.8 : Kirigami.Units.gridUnit * 4.8,
                compactRow.implicitWidth + Kirigami.Units.smallSpacing * 2))

        Layout.minimumWidth: desiredWidth
        Layout.preferredWidth: desiredWidth
        Layout.maximumWidth: desiredWidth
        Layout.maximumHeight: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing * 2

        implicitWidth: desiredWidth
        implicitHeight: Layout.maximumHeight
        clip: true

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: compactRow

            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                readonly property string compactProvider: root.primaryProvider() ? root.primaryProvider().provider : "codex"

                visible: compactRoot.showPrimaryIdentity
                source: loading ? "view-refresh" : root.providerIconSource(compactProvider)
                isMask: !loading && root.providerIconIsMask(compactProvider)
                color: loading ? Kirigami.Theme.textColor : root.providerColor(compactProvider)
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }

            PlasmaComponents.Label {
                visible: compactRoot.primaryText.length > 0
                text: compactRoot.primaryText
                elide: Text.ElideRight
                font.bold: true
                Layout.fillWidth: true
            }

            Repeater {
                model: root.compactProviders()

                delegate: Item {
                    id: compactMeter

                    readonly property real meter: root.switcherPercent(modelData)
                    readonly property color accent: root.providerColor(modelData.provider)

                    Layout.preferredWidth: Kirigami.Units.gridUnit * 1.15
                    Layout.preferredHeight: compactRow.height

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width
                        spacing: 0

                        Kirigami.Icon {
                            source: root.providerIconSource(modelData.provider)
                            isMask: root.providerIconIsMask(modelData.provider)
                            color: compactMeter.accent
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: 9
                            Layout.preferredHeight: 9
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 3
                            radius: height / 2
                            color: root.withAlpha(compactMeter.accent, 0.28)
                            clip: true

                            Rectangle {
                                visible: compactMeter.meter >= 0
                                width: compactMeter.meter <= 0
                                    ? 0
                                    : Math.max(parent.height, parent.width * Math.max(0, Math.min(100, compactMeter.meter)) / 100)
                                height: parent.height
                                radius: parent.radius
                                color: compactMeter.accent
                            }
                        }
                    }
                }
            }
        }
    }

    fullRepresentation: Item {
        id: fullRoot

        implicitWidth: Kirigami.Units.gridUnit * 34
        implicitHeight: Kirigami.Units.gridUnit * 38
        Layout.minimumWidth: Kirigami.Units.gridUnit * 30
        Layout.minimumHeight: Kirigami.Units.gridUnit * 28
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            Flickable {
                id: providerTabsFlickable

                visible: providers.length > 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                contentWidth: providerTabs.implicitWidth
                contentHeight: height
                interactive: contentWidth > width
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.1

                RowLayout {
                    id: providerTabs

                    height: providerTabsFlickable.height
                    spacing: 1

                    Rectangle {
                        id: overviewTab

                        readonly property bool selected: root.overviewSelected
                        readonly property real meter: root.overviewPercent()
                        readonly property color accent: Kirigami.Theme.highlightColor
                        readonly property color foreground: selected ? Kirigami.Theme.highlightedTextColor : root.withAlpha(Kirigami.Theme.textColor, 0.72)

                        visible: root.overviewAvailable
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5.7
                        Layout.preferredHeight: providerTabsFlickable.height
                        radius: Kirigami.Units.smallSpacing
                        color: selected
                            ? root.withAlpha(accent, 0.9)
                            : (overviewTabMouse.containsMouse ? root.withAlpha(Kirigami.Theme.textColor, 0.06) : "transparent")
                        border.width: selected ? 0 : 1
                        border.color: root.withAlpha(Kirigami.Theme.textColor, 0.14)

                        MouseArea {
                            id: overviewTabMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.selectedProviderIndex = -1
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing
                            spacing: 2

                            Kirigami.Icon {
                                source: "view-grid-symbolic"
                                isMask: true
                                color: overviewTab.foreground
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: 16
                                Layout.preferredHeight: 16
                            }

                            PlasmaComponents.Label {
                                text: i18n("Overview")
                                horizontalAlignment: Text.AlignHCenter
                                font.weight: overviewTab.selected ? Font.DemiBold : Font.Normal
                                font.pixelSize: 11
                                color: overviewTab.foreground
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Rectangle {
                                visible: false
                                Layout.fillWidth: true
                                Layout.preferredHeight: 3
                                radius: height / 2
                                color: overviewTab.selected
                                    ? root.withAlpha(overviewTab.foreground, 0.28)
                                    : root.withAlpha(overviewTab.accent, 0.28)
                                clip: true

                                Rectangle {
                                    visible: overviewTab.meter >= 0
                                    width: overviewTab.meter <= 0
                                        ? 0
                                        : Math.max(parent.height, parent.width * Math.max(0, Math.min(100, overviewTab.meter)) / 100)
                                    height: parent.height
                                    radius: parent.radius
                                    color: overviewTab.selected ? overviewTab.foreground : overviewTab.accent
                                }
                            }
                        }
                    }

                    Repeater {
                        model: providers

                        delegate: Rectangle {
                            id: providerTab

                            readonly property bool selected: index === root.selectedProviderIndex
                            readonly property real meter: root.switcherPercent(modelData)
                            readonly property color accent: root.providerColor(modelData.provider)
                            readonly property color selectedAccent: Kirigami.Theme.highlightColor
                            readonly property color foreground: selected ? Kirigami.Theme.highlightedTextColor : root.withAlpha(Kirigami.Theme.textColor, 0.72)

                            Layout.preferredWidth: Math.min(
                                Kirigami.Units.gridUnit * 6.2,
                                Math.max(Kirigami.Units.gridUnit * 3.1, providerTabLabel.implicitWidth + Kirigami.Units.gridUnit))
                            Layout.preferredHeight: providerTabsFlickable.height
                            radius: Kirigami.Units.smallSpacing
                            color: selected
                                ? root.withAlpha(selectedAccent, 0.9)
                                : (providerTabMouse.containsMouse ? root.withAlpha(Kirigami.Theme.textColor, 0.06) : "transparent")
                            border.width: selected ? 0 : 1
                            border.color: root.withAlpha(Kirigami.Theme.textColor, 0.14)
                            opacity: modelData.error.length > 0 ? 0.62 : 1

                            MouseArea {
                                id: providerTabMouse

                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.selectedProviderIndex = index
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                spacing: 2

                                Kirigami.Icon {
                                    source: root.providerIconSource(modelData.provider)
                                    isMask: root.providerIconIsMask(modelData.provider)
                                    color: providerTab.foreground
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: 16
                                    Layout.preferredHeight: 16
                                }

                                PlasmaComponents.Label {
                                    id: providerTabLabel

                                    text: modelData.title
                                    horizontalAlignment: Text.AlignHCenter
                                    font.weight: providerTab.selected ? Font.DemiBold : Font.Normal
                                    font.pixelSize: 11
                                    color: providerTab.foreground
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 2
                                    radius: height / 2
                                    opacity: providerTab.selected ? 0 : 1
                                    color: root.withAlpha(Kirigami.Theme.textColor, 0.16)
                                    clip: true

                                    Rectangle {
                                        visible: !providerTab.selected && providerTab.meter >= 0
                                        width: providerTab.meter <= 0
                                            ? 0
                                            : Math.max(parent.height, parent.width * Math.max(0, Math.min(100, providerTab.meter)) / 100)
                                        height: parent.height
                                        radius: parent.radius
                                        color: providerTab.accent
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
            }

            PlasmaComponents.Label {
                visible: errorText.length > 0
                text: errorText
                color: Kirigami.Theme.negativeTextColor
                Layout.fillWidth: true
                wrapMode: Text.Wrap
            }

            PlasmaComponents.Label {
                visible: providers.length === 0 && errorText.length === 0
                text: loading ? i18n("Loading usage...") : i18n("No provider data.")
                opacity: 0.7
                Layout.fillWidth: true
            }

            ColumnLayout {
                visible: root.overviewSelected
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing / 2

                        Kirigami.Heading {
                            text: i18n("Overview")
                            level: 2
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        PlasmaComponents.Label {
                            text: lastUpdatedText.length > 0
                                ? i18n("%1 · %2 providers", lastUpdatedText, root.overviewProviders().length)
                                : i18n("%1 providers", root.overviewProviders().length)
                            opacity: 0.62
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                    }

                    PlasmaComponents.ToolButton {
                        icon.name: "view-refresh"
                        enabled: !loading
                        Accessible.name: i18n("Refresh")
                        onClicked: root.refreshNow()
                    }
                }

                Controls.ScrollView {
                    id: overviewScroll

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: availableWidth
                    clip: true
                    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

                    ColumnLayout {
                        width: overviewScroll.availableWidth
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents.Label {
                            visible: root.overviewProviders().length === 0
                            text: i18n("No overview data available.")
                            opacity: 0.66
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                        }

                        Repeater {
                            model: root.overviewProviders()

                            delegate: Rectangle {
                                id: overviewRow

                                readonly property color accent: root.providerColor(modelData.provider)
                                readonly property var usageRow: root.switcherMetricRow(modelData)
                                readonly property bool hasUsage: usageRow && usageRow.hasPercent
                                readonly property real shownPercent: hasUsage ? root.displayPercent(usageRow) : -1
                                readonly property string resetText: usageRow ? root.resetLabel(usageRow.reset) : ""
                                readonly property string detail: root.overviewDetailText(modelData)

                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * (detail.length > 0 ? 4.45 : 4.05)
                                radius: Kirigami.Units.smallSpacing
                                color: overviewRowMouse.containsMouse
                                    ? root.withAlpha(Kirigami.Theme.textColor, 0.06)
                                    : "transparent"
                                border.width: 1
                                border.color: root.withAlpha(accent, 0.22)

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing

                                    Rectangle {
                                        Layout.preferredWidth: 3
                                        Layout.fillHeight: true
                                        radius: width / 2
                                        color: overviewRow.accent
                                    }

                                    Kirigami.Icon {
                                        source: root.providerIconSource(modelData.provider)
                                        isMask: root.providerIconIsMask(modelData.provider)
                                        color: overviewRow.accent
                                        Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                        Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Kirigami.Units.smallSpacing

                                            PlasmaComponents.Label {
                                                text: modelData.title
                                                font.weight: Font.DemiBold
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                            }

                                            PlasmaComponents.Label {
                                                visible: overviewRow.hasUsage
                                                text: i18n("%1% %2", Math.round(overviewRow.shownPercent), root.percentSuffix())
                                                opacity: 0.72
                                                horizontalAlignment: Text.AlignRight
                                                elide: Text.ElideRight
                                            }
                                        }

                                        PlasmaComponents.Label {
                                            visible: overviewRow.detail.length > 0
                                            text: overviewRow.detail
                                            opacity: 0.62
                                            Layout.fillWidth: true
                                            elide: Text.ElideMiddle
                                        }

                                        Rectangle {
                                            visible: overviewRow.hasUsage
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 4
                                            radius: height / 2
                                            color: root.withAlpha(Kirigami.Theme.textColor, 0.14)
                                            clip: true

                                            Rectangle {
                                                width: overviewRow.shownPercent <= 0
                                                    ? 0
                                                    : Math.max(parent.height, parent.width * overviewRow.shownPercent / 100)
                                                height: parent.height
                                                radius: parent.radius
                                                color: overviewRow.accent
                                            }
                                        }

                                        PlasmaComponents.Label {
                                            visible: overviewRow.resetText.length > 0
                                            text: overviewRow.resetText
                                            opacity: 0.56
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                MouseArea {
                                    id: overviewRowMouse

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.selectedProviderIndex = root.providerIndex(modelData)
                                }
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                visible: root.selectedProviderData !== null
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing / 2

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            Kirigami.Heading {
                                text: root.selectedProviderData ? root.selectedProviderData.title : ""
                                level: 2
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            PlasmaComponents.Label {
                                visible: root.selectedProviderData
                                    && root.selectedProviderData.account
                                    && root.selectedProviderData.account.length > 0
                                text: root.selectedProviderData ? root.selectedProviderData.account : ""
                                opacity: 0.62
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideMiddle
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 16
                            }

                            PlasmaComponents.ToolButton {
                                icon.name: "view-refresh"
                                enabled: !loading
                                Accessible.name: i18n("Refresh")
                                onClicked: root.refreshNow()
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents.Label {
                                text: lastUpdatedText.length > 0 ? lastUpdatedText : i18n("Updated just now")
                                opacity: 0.62
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            PlasmaComponents.Label {
                                visible: root.selectedProviderData
                                    && root.selectedProviderData.planText
                                    && root.selectedProviderData.planText.length > 0
                                text: root.selectedProviderData ? root.selectedProviderData.planText : ""
                                opacity: 0.66
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                PlasmaComponents.Label {
                    visible: root.selectedProviderData
                        && root.selectedProviderData.status
                        && root.selectedProviderData.status.length > 0
                    text: root.selectedProviderData ? root.selectedProviderData.status : ""
                    opacity: 0.7
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                }

                PlasmaComponents.Label {
                    visible: root.selectedProviderData
                        && root.selectedProviderData.error
                        && root.selectedProviderData.error.length > 0
                    text: root.selectedProviderData ? root.selectedProviderData.error : ""
                    color: Kirigami.Theme.negativeTextColor
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                }

                Controls.ScrollView {
                    id: providerScroll

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: availableWidth
                    clip: true
                    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

                    ColumnLayout {
                        width: providerScroll.availableWidth
                        spacing: Kirigami.Units.largeSpacing

                        PlasmaComponents.Label {
                            visible: root.providerPlaceholderText(root.selectedProviderData).length > 0
                            text: root.providerPlaceholderText(root.selectedProviderData)
                            opacity: 0.66
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                        }

                        Repeater {
                            model: root.selectedProviderData ? root.selectedProviderData.rows : []

                            delegate: ColumnLayout {
                                readonly property color accent: root.providerColor(root.selectedProviderData ? root.selectedProviderData.provider : "")
                                readonly property real shownPercent: root.displayPercent(modelData)
                                readonly property real markerPercent: root.paceMarkerPercent(modelData)

                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing / 1.5

                                PlasmaComponents.Label {
                                    text: modelData.label
                                    font.weight: Font.DemiBold
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    visible: modelData.hasPercent
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 6
                                    radius: height / 2
                                    color: root.withAlpha(Kirigami.Theme.textColor, 0.14)
                                    clip: true

                                    Rectangle {
                                        width: shownPercent <= 0
                                            ? 0
                                            : Math.max(parent.height, parent.width * shownPercent / 100)
                                        height: parent.height
                                        radius: parent.radius
                                        color: accent
                                    }

                                    Rectangle {
                                        visible: markerPercent > 0 && markerPercent < 100
                                        x: Math.max(0, Math.min(parent.width - width, parent.width * markerPercent / 100 - width / 2))
                                        y: 1
                                        width: 2
                                        height: parent.height - 2
                                        radius: width / 2
                                        color: modelData.paceOnTop
                                            ? root.withAlpha(Kirigami.Theme.positiveTextColor, 0.9)
                                            : root.withAlpha(Kirigami.Theme.negativeTextColor, 0.9)
                                    }
                                }

                                RowLayout {
                                    visible: modelData.hasPercent || root.resetLabel(modelData.reset).length > 0
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    PlasmaComponents.Label {
                                        visible: modelData.hasPercent
                                        text: i18n("%1% %2", Math.round(shownPercent), root.percentSuffix())
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }

                                    PlasmaComponents.Label {
                                        visible: root.resetLabel(modelData.reset).length > 0
                                        text: root.resetLabel(modelData.reset)
                                        opacity: 0.66
                                        horizontalAlignment: Text.AlignRight
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                                    }
                                }

                                PlasmaComponents.Label {
                                    visible: modelData.pace.length > 0
                                    text: modelData.pace
                                    opacity: 0.66
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }

                        Kirigami.Separator {
                            visible: root.hasAdditionalSections(root.selectedProviderData)
                            Layout.fillWidth: true
                        }

                        ColumnLayout {
                            visible: root.selectedProviderData && root.selectedProviderData.credits !== null
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing / 1.5

                            Kirigami.Heading {
                                text: i18n("Credits")
                                level: 4
                                Layout.fillWidth: true
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 6
                                radius: height / 2
                                color: root.withAlpha(Kirigami.Theme.textColor, 0.14)
                                clip: true

                                Rectangle {
                                    width: root.selectedProviderData && root.selectedProviderData.credits > 0
                                        ? Math.max(parent.height, parent.width * Math.min(root.selectedProviderData.credits, 1000) / 1000)
                                        : 0
                                    height: parent.height
                                    radius: parent.radius
                                    color: root.providerColor(root.selectedProviderData ? root.selectedProviderData.provider : "")
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                PlasmaComponents.Label {
                                    text: i18n("Remaining: %1", root.selectedProviderData ? root.formatNumber(root.selectedProviderData.credits) : "")
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        ColumnLayout {
                            id: resetCreditsSection

                            readonly property var resetCredits: root.selectedProviderData ? root.selectedProviderData.resetCredits : null

                            visible: resetCreditsSection.resetCredits ? true : false
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing / 1.5

                            Kirigami.Separator {
                                Layout.fillWidth: true
                            }

                            Kirigami.Heading {
                                text: resetCreditsSection.resetCredits ? resetCreditsSection.resetCredits.title : ""
                                level: 4
                                Layout.fillWidth: true
                            }

                            PlasmaComponents.Label {
                                text: resetCreditsSection.resetCredits ? resetCreditsSection.resetCredits.line : ""
                                opacity: 0.7
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }

                        ColumnLayout {
                            id: providerCostSection

                            readonly property var providerCost: root.selectedProviderData ? root.selectedProviderData.providerCost : null
                            readonly property color accent: root.providerColor(root.selectedProviderData ? root.selectedProviderData.provider : "")

                            visible: providerCostSection.providerCost ? true : false
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing / 1.5

                            Kirigami.Separator {
                                Layout.fillWidth: true
                            }

                            Kirigami.Heading {
                                text: providerCostSection.providerCost ? providerCostSection.providerCost.title : ""
                                level: 4
                                Layout.fillWidth: true
                            }

                            Rectangle {
                                visible: providerCostSection.providerCost && providerCostSection.providerCost.percentUsed >= 0 ? true : false
                                Layout.fillWidth: true
                                Layout.preferredHeight: 6
                                radius: height / 2
                                color: root.withAlpha(Kirigami.Theme.textColor, 0.14)
                                clip: true

                                Rectangle {
                                    width: providerCostSection.providerCost && providerCostSection.providerCost.percentUsed > 0
                                        ? Math.max(parent.height, parent.width * providerCostSection.providerCost.percentUsed / 100)
                                        : 0
                                    height: parent.height
                                    radius: parent.radius
                                    color: providerCostSection.accent
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                PlasmaComponents.Label {
                                    text: providerCostSection.providerCost ? providerCostSection.providerCost.spendLine : ""
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }

                                PlasmaComponents.Label {
                                    visible: providerCostSection.providerCost && providerCostSection.providerCost.percentLine.length > 0 ? true : false
                                    text: providerCostSection.providerCost ? providerCostSection.providerCost.percentLine : ""
                                    opacity: 0.66
                                    horizontalAlignment: Text.AlignRight
                                    elide: Text.ElideRight
                                }
                            }

                            PlasmaComponents.Label {
                                visible: providerCostSection.providerCost && providerCostSection.providerCost.personalSpendLine.length > 0 ? true : false
                                text: providerCostSection.providerCost ? providerCostSection.providerCost.personalSpendLine : ""
                                opacity: 0.66
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }

                        ColumnLayout {
                            id: tokenCostSection

                            readonly property var tokenCost: root.selectedProviderData ? root.selectedProviderData.tokenCost : null

                            visible: tokenCostSection.tokenCost ? true : false
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing / 1.5

                            Kirigami.Separator {
                                Layout.fillWidth: true
                            }

                            Kirigami.Heading {
                                text: i18n("Cost")
                                level: 4
                                Layout.fillWidth: true
                            }

                            PlasmaComponents.Label {
                                text: tokenCostSection.tokenCost ? tokenCostSection.tokenCost.sessionLine : ""
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            PlasmaComponents.Label {
                                text: tokenCostSection.tokenCost ? tokenCostSection.tokenCost.monthLine : ""
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            PlasmaComponents.Label {
                                visible: tokenCostSection.tokenCost && tokenCostSection.tokenCost.hintLine.length > 0 ? true : false
                                text: tokenCostSection.tokenCost ? tokenCostSection.tokenCost.hintLine : ""
                                opacity: 0.62
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                            }
                        }

                        ColumnLayout {
                            visible: root.selectedProviderData !== null
                            Layout.fillWidth: true
                            spacing: 0

                            Kirigami.Separator {
                                Layout.fillWidth: true
                            }

                            Repeater {
                                model: root.selectedProviderData ? root.actionRows(root.selectedProviderData) : []

                                delegate: Controls.ItemDelegate {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    icon.name: modelData.icon
                                    enabled: modelData.enabled
                                    onClicked: root.performAction(modelData)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
