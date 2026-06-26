import CodexBarCore
import Commander
import Testing
@testable import CodexBarCLI

struct CLIConfigCommandTests {
    @Test
    func `config set api key parses provider stdin and no enable flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configSetAPIKeySignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "elevenlabs",
            "--stdin",
            "--no-enable",
            "--json",
        ])

        #expect(parsed.options["provider"] == ["elevenlabs"])
        #expect(parsed.flags.contains("stdin"))
        #expect(parsed.flags.contains("noEnable"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `config set api key parses zai team account options`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configSetAPIKeySignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "zai",
            "--stdin",
            "--label", "Team",
            "--usage-scope", "team",
            "--organization-id", "org-team",
            "--workspace-id", "proj-team",
        ])

        #expect(parsed.options["provider"] == ["zai"])
        #expect(parsed.options["label"] == ["Team"])
        #expect(parsed.options["usageScope"] == ["team"])
        #expect(parsed.options["organizationId"] == ["org-team"])
        #expect(parsed.options["workspaceId"] == ["proj-team"])
    }

    @Test
    func `config set api key stores key and enables provider`() {
        let config = CodexBarConfig.makeDefault()
        let updated = CodexBarCLI.configSettingAPIKey(
            config,
            provider: .elevenlabs,
            apiKey: "xi-test-token",
            enableProvider: true)
        let provider = updated.providerConfig(for: .elevenlabs)

        #expect(provider?.sanitizedAPIKey == "xi-test-token")
        #expect(provider?.enabled == true)
    }

    @Test
    func `config set api key stores zai team token account`() throws {
        let config = CodexBarConfig.makeDefault()
        let options = try CodexBarCLI.resolveConfigAPIKeyAccountOptions(
            provider: .zai,
            label: "Team",
            usageScope: "team",
            organizationID: " org-team ",
            workspaceID: " proj-team ")
        let updated = CodexBarCLI.configSettingAPIKey(
            config,
            provider: .zai,
            apiKey: "z-token",
            enableProvider: true,
            accountOptions: options)
        let provider = try #require(updated.providerConfig(for: .zai))
        let account = try #require(provider.tokenAccounts?.accounts.first)

        #expect(provider.enabled == true)
        #expect(provider.apiKey == nil)
        #expect(provider.tokenAccounts?.activeIndex == 0)
        #expect(account.label == "Team")
        #expect(account.token == "z-token")
        #expect(account.usageScope == "team")
        #expect(account.organizationID == "org-team")
        #expect(account.workspaceID == "proj-team")
    }

    @Test
    func `config set api key rejects incomplete zai team account options`() {
        #expect(throws: CLIArgumentError.self) {
            _ = try CodexBarCLI.resolveConfigAPIKeyAccountOptions(
                provider: .zai,
                label: "Team",
                usageScope: "team",
                organizationID: "org-team",
                workspaceID: nil)
        }
    }

    @Test
    func `config provider toggle parses provider and json flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configProviderToggleSignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "grok",
            "--json",
            "--pretty",
        ])

        #expect(parsed.options["provider"] == ["grok"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
        #expect(parsed.flags.contains("pretty"))
    }

    @Test
    func `config provider toggle enables and disables provider`() {
        let config = CodexBarConfig.makeDefault()
        let enabled = CodexBarCLI.configSettingProviderEnabled(config, provider: .grok, enabled: true)
        let disabled = CodexBarCLI.configSettingProviderEnabled(enabled, provider: .grok, enabled: false)

        #expect(enabled.providerConfig(for: .grok)?.enabled == true)
        #expect(disabled.providerConfig(for: .grok)?.enabled == false)
    }

    @Test
    func `config provider status includes effective default`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .grok, enabled: true),
            ProviderConfig(id: .cursor, enabled: false),
        ])
        let statuses = CodexBarCLI.configProviderStatuses(config)
        let grok = try #require(statuses.first { $0.provider == "grok" })
        let cursor = try #require(statuses.first { $0.provider == "cursor" })

        #expect(grok.enabled)
        #expect(!cursor.enabled)
        #expect(statuses.count == UsageProvider.allCases.count)
    }

    @Test
    func `config providers parses descriptors flag`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configProvidersSignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--descriptors",
            "--json-only",
        ])

        #expect(parsed.flags.contains("descriptors"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `config set parses provider field value and json flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configSetFieldSignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "amp",
            "--field", "sourceMode",
            "--value", "api",
            "--json-only",
        ])

        #expect(parsed.options["provider"] == ["amp"])
        #expect(parsed.options["field"] == ["sourceMode"])
        #expect(parsed.options["value"] == ["api"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `config action parses provider action and json flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configActionSignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "openai",
            "--action", "openDashboard",
            "--json-only",
        ])

        #expect(parsed.options["provider"] == ["openai"])
        #expect(parsed.options["action"] == ["openDashboard"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `config provider descriptors include redacted api key write command`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .elevenlabs, enabled: true, apiKey: "xi-secret-token"),
        ])
        let statuses = CodexBarCLI.configProviderStatuses(config, includeDescriptors: true)
        let elevenLabs = try #require(statuses.first { $0.provider == "elevenlabs" })
        let descriptor = try #require(elevenLabs.descriptor)
        let field = try #require(descriptor.fields.first { $0.id == "apiKey" })

        #expect(descriptor.schemaVersion == 1)
        #expect(field.kind == "secret")
        #expect(field.title == "API key")
        #expect(field.redactedValue == "configured")
        #expect(field.writeCommand == [
            "codexbar",
            "config",
            "set",
            "--provider",
            "elevenlabs",
            "--field",
            "apiKey",
            "--stdin",
            "--json-only",
        ])
    }

    @Test
    func `config provider descriptors include generic source cookie and dashboard actions`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .amp,
                enabled: true,
                source: .web,
                cookieSource: .manual,
                cookieHeader: "amp-cookie"),
        ])
        let statuses = CodexBarCLI.configProviderStatuses(config, includeDescriptors: true)
        let amp = try #require(statuses.first { $0.provider == "amp" })
        let descriptor = try #require(amp.descriptor)
        let source = try #require(descriptor.fields.first { $0.id == "sourceMode" })
        let cookieSource = try #require(descriptor.fields.first { $0.id == "cookieSource" })
        let cookieHeader = try #require(descriptor.fields.first { $0.id == "cookieHeader" })
        let dashboard = try #require(descriptor.actions.first { $0.id == "openDashboard" })

        #expect(source.kind == "enum")
        #expect(source.value == "web")
        #expect(source.options?.map(\.id) == ["auto", "web", "cli", "api"])
        #expect(source.writeCommand?.contains("{value}") == true)
        #expect(cookieSource.kind == "enum")
        #expect(cookieSource.value == "manual")
        #expect(cookieHeader.kind == "secret")
        #expect(cookieHeader.redactedValue == "configured")
        #expect(dashboard.command == [
            "codexbar",
            "config",
            "action",
            "--provider",
            "amp",
            "--action",
            "openDashboard",
            "--json-only",
        ])
    }

    @Test
    func `config set stores generic provider fields`() throws {
        var config = CodexBarConfig.makeDefault()
        config = try CodexBarCLI.configSettingProviderField(
            config,
            provider: .amp,
            field: .sourceMode,
            value: "api")
        config = try CodexBarCLI.configSettingProviderField(
            config,
            provider: .amp,
            field: .cookieSource,
            value: "manual")
        config = try CodexBarCLI.configSettingProviderField(
            config,
            provider: .amp,
            field: .cookieHeader,
            value: "cookie=value")

        let amp = try #require(config.providerConfig(for: .amp))
        #expect(amp.source == .api)
        #expect(amp.cookieSource == .manual)
        #expect(amp.sanitizedCookieHeader == "cookie=value")
    }

    @Test
    func `config set api key only accepts consumed config keys`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .elevenlabs))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .groq))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .llmproxy))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .openai))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .amp))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .kimi))
        #expect(!ProviderConfigEnvironment.supportsAPIKeyOverride(for: .bedrock))
        #expect(!ProviderConfigEnvironment.supportsAPIKeyOverride(for: .deepseek))
        #expect(!ProviderConfigEnvironment.supportsAPIKeyOverride(for: .cursor))
    }

    @Test
    func `config set api key preserves disabled provider when requested`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .elevenlabs, enabled: false))

        let updated = CodexBarCLI.configSettingAPIKey(
            config,
            provider: .elevenlabs,
            apiKey: "xi-test-token",
            enableProvider: false)
        let provider = updated.providerConfig(for: .elevenlabs)

        #expect(provider?.sanitizedAPIKey == "xi-test-token")
        #expect(provider?.enabled == false)
    }

    @Test
    func `config set api key rejects ambiguous input`() {
        #expect(throws: CLIArgumentError.self) {
            try CodexBarCLI.resolveConfigAPIKeyInput(apiKey: "xi-test-token", readFromStdin: true)
        }
    }

    @Test
    func `config help documents set api key`() {
        let help = CodexBarCLI.configHelp(version: "0.0.0")

        #expect(help.contains("config set-api-key --provider <name>"))
        #expect(help.contains("config providers"))
        #expect(help.contains("config set --provider <name> --field <field>"))
        #expect(help.contains("config action --provider <name> --action <action>"))
        #expect(help.contains("config enable --provider <name>"))
        #expect(help.contains("config disable --provider <name>"))
        #expect(help.contains("--stdin"))
        #expect(help.contains("--usage-scope team"))
        #expect(help.contains("enables that provider by default"))
    }
}
