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

    private func settingValue(_ key: String, inGetResult result: Value) -> Value? {
        result.objectValue?["values"]?.objectValue?[key]
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
