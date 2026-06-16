@testable import RepoPrompt
import XCTest

final class WorkflowPromptCatalogTests: XCTestCase {
    func testWorkflowCommandOrdersAndNamesStayStable() {
        XCTAssertEqual(
            RepoPromptWorkflowID.mcpPromptOrder.map(\.commandName),
            [
                "rp-build",
                "rp-investigate",
                "rp-deep-plan",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize"
            ]
        )
        XCTAssertEqual(
            RepoPromptWorkflowID.installOrder.map(\.commandName),
            [
                "rp-investigate",
                "rp-build",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize",
                "rp-deep-plan"
            ]
        )
        XCTAssertEqual(RepoPromptWorkflowID.allCases.count, 9)
    }

    func testCatalogMetadataMatchesWorkflowIDs() {
        XCTAssertEqual(WorkflowPromptCatalog.descriptors.count, RepoPromptWorkflowID.allCases.count)
        XCTAssertEqual(WorkflowPromptCatalog.mcpPromptDescriptors.map(\.id), RepoPromptWorkflowID.mcpPromptOrder)
        XCTAssertEqual(WorkflowPromptCatalog.installDescriptors.map(\.id), RepoPromptWorkflowID.installOrder)

        for descriptor in WorkflowPromptCatalog.descriptors {
            XCTAssertEqual(descriptor.name, descriptor.id.commandName)
            XCTAssertFalse(descriptor.description.isEmpty, descriptor.name)
        }
    }

    func testRenderedManagedPromptFrontmatterCompatibility() {
        XCTAssertEqual(RepoPromptWorkflowPrompts.skillsVersion, 62)

        for descriptor in WorkflowPromptCatalog.installDescriptors {
            let rendered = RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: .mcp)
            XCTAssertTrue(rendered.hasPrefix("---\n"), descriptor.name)
            XCTAssertTrue(rendered.contains("name: \"\(descriptor.name)\""), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_managed: true"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_skills_version: 62"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_variant: mcp"), descriptor.name)
            XCTAssertFalse(RepoPromptWorkflowPrompts.stripYAMLFrontmatter(rendered).hasPrefix("---"), descriptor.name)
        }
    }

    func testAgentWorkflowTemplatesRenderFromProviderNeutralCatalog() {
        for workflow in AgentWorkflow.allCases {
            let rendered = RepoPromptWorkflowPrompts.render(id: workflow.workflowPromptID, variant: .agent)
            XCTAssertFalse(rendered.isEmpty, workflow.rawValue)
            XCTAssertEqual(workflow.template, rendered, workflow.rawValue)
        }
    }

    func testAgentOrchestratePromptKeepsDelegationInsideManagedAgentRun() {
        let rendered = RepoPromptWorkflowPrompts.render(id: .orchestrate, variant: .agent)

        XCTAssertTrue(rendered.contains("Agent Mode delegation boundary"))
        XCTAssertTrue(rendered.contains("use RepoPrompt-managed `agent_run` / `agent_manage` sessions"))
        XCTAssertTrue(rendered.contains("Do not create sub-agents by shelling out to external agent CLIs"))
        XCTAssertTrue(rendered.contains("`pi -p`"))
        XCTAssertTrue(rendered.contains("If `agent_run` is unavailable, stop and report the blocker"))
    }

    func testAgentReviewPromptUsesContextBuilderAndOracleInsideManagedAgentMode() {
        let rendered = RepoPromptWorkflowPrompts.render(id: .review, variant: .agent)

        XCTAssertTrue(rendered.contains("response_type: \"review\""), rendered)
        XCTAssertTrue(rendered.contains("context_builder"), rendered)
        XCTAssertTrue(rendered.contains("ask_oracle"), rendered)
        XCTAssertFalse(rendered.contains("oracle_send"), rendered)
    }

    func testAgentDeepPlanPromptKeepsPlanningDelegationInsideManagedAgentMode() {
        let rendered = RepoPromptWorkflowPrompts.render(id: .deepPlan, variant: .agent)

        XCTAssertTrue(rendered.contains("agent_run"), rendered)
        XCTAssertTrue(rendered.contains("\"model_id\":\"explore\""), rendered)
        XCTAssertTrue(rendered.contains("\"model_id\":\"design\""), rendered)
        XCTAssertTrue(rendered.contains("context_builder"), rendered)
        XCTAssertTrue(rendered.contains("ask_oracle"), rendered)
        XCTAssertFalse(rendered.contains("oracle_send"), rendered)
    }

    func testTopLevelAgentModePromptForbidsExternalAgentCLIDelegation() {
        let prompt = SystemPromptService.agentModePrompt(agentKind: .pi)

        XCTAssertTrue(prompt.contains("Do not spawn child agents by running external agent CLIs"))
        XCTAssertTrue(prompt.contains("Use `agent_run` instead"))
        XCTAssertTrue(prompt.contains("`pi -p`"))
        XCTAssertTrue(prompt.contains("bypass RepoPrompt's managed session store"))
    }
}
