import Foundation
@testable import RepoPrompt
import XCTest

final class ClaudeNativeIdentityPreambleTests: XCTestCase {
    private func makeController(variant: ClaudeCodeRuntimeVariant) -> ClaudeNativeProcessSessionController {
        ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(modelString: nil, runtimeVariant: variant)
        )
    }

    func testGLMLaunchEnvironmentAppendsIdentityPreambleFlag() async throws {
        let args = await makeController(variant: .glm).test_buildArguments(
            existingSessionID: nil,
            model: nil,
            launchEnvironment: ClaudeCodeLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backend: .compatible(.glmZAI)
            )
        )

        let flagIndex = try XCTUnwrap(args.firstIndex(of: "--append-system-prompt"))
        XCTAssertEqual(
            args[args.index(after: flagIndex)],
            ClaudeCompatibleProviderRuntimeBridge.identityAppendSystemPrompt(for: ClaudeCodeLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backend: .compatible(.glmZAI)
            ))
        )
    }

    func testNonGLMLaunchEnvironmentsDoNotAppendIdentityPreambleFlag() async {
        for backend in [ClaudeCodeLaunchEnvironment.Backend.defaultClaude, .compatible(.kimi), .compatible(.custom)] {
            let args = await makeController(variant: .standard).test_buildArguments(
                existingSessionID: nil,
                model: nil,
                launchEnvironment: ClaudeCodeLaunchEnvironment(
                    effectiveModel: nil,
                    environmentOverrides: [:],
                    backend: backend
                )
            )
            XCTAssertFalse(args.contains("--append-system-prompt"), "\(backend) must not append a system prompt")
        }
    }
}
