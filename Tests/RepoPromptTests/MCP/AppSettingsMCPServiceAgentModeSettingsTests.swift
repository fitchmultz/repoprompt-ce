import Foundation
import MCP
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AppSettingsMCPServiceAgentModeSettingsTests: XCTestCase {
    func testCodexReasoningSummariesSettingDefaultsOffAndPersistsThroughAppSettings() async throws {
        let (store, fileStore) = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))
        let service = AppSettingsMCPService(store: store)
        let tools = await service.tools
        let tool = try XCTUnwrap(tools.first { $0.name == AppSettingsMCPService.toolName })
        let key = "agent_mode.codex_reasoning_summaries_enabled"

        let initial = try await tool(["op": Value.string("get"), "key": Value.string(key)])
        XCTAssertEqual(settingValue(key, inGetResult: initial)?.boolValue, false)
        XCTAssertFalse(store.codexReasoningSummariesEnabled())

        let setResult = try await tool(["op": Value.string("set"), "key": Value.string(key), "value": Value.bool(true)])
        XCTAssertEqual(setResult.objectValue?["new_value"]?.boolValue, true)
        XCTAssertTrue(store.codexReasoningSummariesEnabled())

        let persisted = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        XCTAssertTrue(persisted.codexReasoningSummariesEnabled())
    }

    func testBlankPreferredComposeAppSettingDoesNotBlankOracleWhenSyncOn() async throws {
        let (store, fileStore) = try makeStore(document: GlobalSettingsDocument())
        let model = AIModel.codexCustom(name: "gpt-5.5-high").rawValue

        store.setSyncChatModelWithOracle(true)
        store.setPlanningModelRaw(model, commit: true)
        _ = try await executeAppSettings(store: store, arguments: ["op": Value.string("set"), "key": Value.string("models.preferred_compose_model"), "value": Value.null])
        _ = try await executeAppSettings(store: store, arguments: ["op": Value.string("set"), "key": Value.string("models.preferred_compose_model"), "value": Value.string("   ")])

        XCTAssertEqual(store.planningModelRaw(), model)
        let persisted = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        XCTAssertEqual(persisted.planningModelRaw(), model)
    }

    func testRealPreferredComposeAppSettingStillMirrorsOracleWhenSyncOn() async throws {
        let (store, _) = try makeStore(document: GlobalSettingsDocument())
        let newModel = AIModel.codexCustom(name: "gpt-5.5-low").rawValue

        store.setSyncChatModelWithOracle(true)
        _ = try await executeAppSettings(store: store, arguments: ["op": Value.string("set"), "key": Value.string("models.preferred_compose_model"), "value": Value.string(newModel)])

        XCTAssertEqual(store.planningModelRaw(), newModel)
    }

    private func settingValue(_ key: String, inGetResult result: Value) -> Value? {
        result.objectValue?["values"]?.objectValue?[key]
    }

    private func executeAppSettings(store: GlobalSettingsStore, arguments: [String: Value]) async throws -> Value {
        let service = AppSettingsMCPService(store: store)
        let result = try await service.call(tool: AppSettingsMCPService.toolName, with: arguments)
        return try XCTUnwrap(result)
    }

    private func makeStore(document: GlobalSettingsDocument) throws -> (GlobalSettingsStore, GlobalSettingsFileStore) {
        let fileStore = try makeFileStore()
        try fileStore.save(document)
        let store = try GlobalSettingsStore(defaults: makeIsolatedDefaults(), fileStore: fileStore)
        return (store, fileStore)
    }

    private func makeFileStore() throws -> GlobalSettingsFileStore {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsMCPServiceAgentModeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }
        return GlobalSettingsFileStore(fileURL: temp.appendingPathComponent("Settings/globalSettings.json"))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "AppSettingsMCPServiceAgentModeSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
