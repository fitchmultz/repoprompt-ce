import Foundation

/// Provider-specific MCP connection semantics shared by Agent Mode and headless Context Builder runs.
///
/// The run owner still chooses the normal requested TTL; providers that keep a long-lived native
/// session and spawn per-tool helper processes can extend that TTL and disable one-shot cleanup in
/// one documented place instead of scattering exceptions through lease builders.
struct AgentMCPConnectionPolicyProfile: Equatable {
    let oneShot: Bool
    let ttl: TimeInterval
    let requiresExpectedAgentPID: Bool

    private static let sessionCapableRPCBridgeTTL: TimeInterval = 3600

    static func agentMode(agent: AgentProviderKind, requestedTTL: TimeInterval) -> AgentMCPConnectionPolicyProfile {
        if agent == .pi {
            return sessionCapableBridgeProfile(requestedTTL: requestedTTL)
        }
        return AgentMCPConnectionPolicyProfile(
            oneShot: true,
            ttl: requestedTTL,
            requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting
        )
    }

    static func headless(agent: AgentProviderKind, requestedTTL: TimeInterval) -> AgentMCPConnectionPolicyProfile {
        if agent == .pi {
            return sessionCapableBridgeProfile(requestedTTL: requestedTTL)
        }
        return AgentMCPConnectionPolicyProfile(
            oneShot: true,
            ttl: requestedTTL,
            requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting
        )
    }

    private static func sessionCapableBridgeProfile(requestedTTL: TimeInterval) -> AgentMCPConnectionPolicyProfile {
        AgentMCPConnectionPolicyProfile(
            oneShot: false,
            ttl: max(requestedTTL, sessionCapableRPCBridgeTTL),
            requiresExpectedAgentPID: true
        )
    }
}
