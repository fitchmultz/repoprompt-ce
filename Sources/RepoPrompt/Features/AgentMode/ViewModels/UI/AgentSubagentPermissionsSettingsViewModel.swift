//
//  AgentSubagentPermissionsSettingsViewModel.swift
//  RepoPrompt
//
//  Focused view model for sub-agent sandbox override policy.
//

import Combine
import Foundation

@MainActor
final class AgentSubagentPermissionsSettingsViewModel: ObservableObject {
    @Published private(set) var globalPolicy: AgentSubagentPermissionPolicy
    @Published private(set) var providerPermissionLevelsByID: [AgentProviderBindingID: AgentProviderPermissionLevelID]
    /// Bumps when policy or diagnostics are re-read so SwiftUI refreshes derived previews.
    @Published private(set) var revision: Int = 0

    let defaults: UserDefaults
    let securePermissions: AgentPermissionSecureStore?
    let diagnostics: AgentPermissionStorageDiagnosticsViewModel

    private let notificationCenter: NotificationCenter
    private let onPolicyChanged: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    init(
        defaults: UserDefaults = .standard,
        securePermissions: AgentPermissionSecureStore? = nil,
        diagnostics: AgentPermissionStorageDiagnosticsViewModel? = nil,
        notificationCenter: NotificationCenter = .default,
        onPolicyChanged: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        let resolvedSecure: AgentPermissionSecureStore? = if let securePermissions {
            securePermissions
        } else if defaults === UserDefaults.standard {
            AgentPermissionSecureStore.shared
        } else {
            nil
        }
        self.securePermissions = resolvedSecure
        self.diagnostics = diagnostics ?? AgentPermissionStorageDiagnosticsViewModel(
            securePermissions: resolvedSecure,
            notificationCenter: notificationCenter
        )
        self.notificationCenter = notificationCenter
        self.onPolicyChanged = onPolicyChanged
        globalPolicy = AgentModePermissionPreferences.subagentPermissionPolicy(
            defaults: defaults,
            secureStore: resolvedSecure
        )
        providerPermissionLevelsByID = Self.loadProviderPermissionLevels(
            defaults: defaults,
            securePermissions: resolvedSecure
        )
        subscribeToSecureStoreChanges()
    }

    var storageDiagnostics: [AgentPermissionStorageDiagnostic] {
        diagnostics.storageDiagnostics
    }

    var isSecurePermissionStorageDegraded: Bool {
        diagnostics.isSecurePermissionStorageDegraded
    }

    func setGlobalPolicy(_ policy: AgentSubagentPermissionPolicy) {
        guard policy != globalPolicy else { return }
        AgentModePermissionPreferences.setSubagentPermissionPolicy(
            policy,
            defaults: defaults,
            secureStore: securePermissions
        )
        // Re-read so failed secure writes snap back to the effective persisted value.
        refreshFromStorage(notifyPolicyChange: true)
    }

    func setProviderPermissionLevel(
        _ level: AgentProviderPermissionLevelID,
        for providerID: AgentProviderBindingID
    ) {
        guard providerPermissionLevelsByID[providerID] != level else { return }
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            level,
            for: providerID,
            defaults: defaults,
            secureStore: securePermissions
        )
        refreshFromStorage(notifyPolicyChange: true)
    }

    func refreshFromStorage(notifyPolicyChange: Bool = false) {
        let previousPolicy = globalPolicy
        let previousProviderLevels = providerPermissionLevelsByID
        globalPolicy = AgentModePermissionPreferences.subagentPermissionPolicy(
            defaults: defaults,
            secureStore: securePermissions
        )
        providerPermissionLevelsByID = Self.loadProviderPermissionLevels(
            defaults: defaults,
            securePermissions: securePermissions
        )
        diagnostics.refresh()
        revision &+= 1
        if notifyPolicyChange,
           previousPolicy != globalPolicy || previousProviderLevels != providerPermissionLevelsByID
        {
            onPolicyChanged?()
        }
    }

    func safeManagedSummaries(
        availability: AgentModelCatalog.AvailabilityContext
    ) -> [AgentPermissionCapabilitySummary] {
        _ = revision
        return AgentPermissionCapabilitySummaryBuilder(
            defaults: defaults,
            securePermissions: securePermissions
        ).summaries(profile: .mcpSafeDefaults, availability: availability)
    }

    private static func loadProviderPermissionLevels(
        defaults: UserDefaults,
        securePermissions: AgentPermissionSecureStore?
    ) -> [AgentProviderBindingID: AgentProviderPermissionLevelID] {
        var providerMap: [AgentProviderBindingID: AgentProviderPermissionLevelID] = [:]
        for id in AgentProviderBindingID.allCases {
            providerMap[id] = AgentModePermissionPreferences.providerSubagentPermissionLevel(
                for: id,
                defaults: defaults,
                secureStore: securePermissions
            )
        }
        return providerMap
    }

    private func subscribeToSecureStoreChanges() {
        notificationCenter.publisher(for: .agentPermissionSecureStoreDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let isSubagentDomain = notification.userInfo?[AgentPermissionSecureStoreNotificationKey.domain] as? String == AgentPermissionSecureDomain.subagent.rawValue
                self?.refreshFromStorage(notifyPolicyChange: isSubagentDomain)
            }
            .store(in: &cancellables)
    }
}
