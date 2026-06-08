import Foundation

@MainActor
enum AgentModeMCPPolicyInstaller {
    static let policyTTL: TimeInterval = 60
    static let policyReason = "agent-mode-run"

    static func additionalTools(for agent: AgentProviderKind) -> Set<String> {
        AgentModeMCPToolPolicy.grantedTools(forAgent: agent)
    }

    static func install(
        agent: AgentProviderKind,
        windowID: Int,
        tabID: UUID,
        runID: UUID,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        connectionPolicyInstaller: AgentModeViewModel.ConnectionPolicyInstaller
    ) async {
        let leaseSpec = MCPBootstrapLeaseSpec.agentMode(
            tabID: tabID,
            runID: runID,
            gateID: runID,
            windowID: windowID,
            agent: agent,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools
        )
        guard let clientName = leaseSpec.clientName else { return }
        await connectionPolicyInstaller(
            clientName,
            leaseSpec.windowID,
            leaseSpec.restrictedTools,
            leaseSpec.oneShot,
            leaseSpec.reason,
            leaseSpec.ttl,
            leaseSpec.tabID,
            leaseSpec.runID,
            leaseSpec.additionalTools,
            leaseSpec.purpose,
            leaseSpec.taskLabelKind,
            leaseSpec.allowsAgentExternalControlTools,
            leaseSpec.requiresExpectedAgentPID
        )
    }
}
