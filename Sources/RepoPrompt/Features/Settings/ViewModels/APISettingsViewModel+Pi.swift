import Foundation

extension APISettingsViewModel {
    // MARK: - pi RPC

    func setPiManagedRunsAllowDiscoveredExtensions(_ allow: Bool) {
        guard piManagedRunsAllowDiscoveredExtensions != allow else { return }
        piPreflightTask?.cancel()
        piPreflightTask = nil
        piPolicyChangeTask?.cancel()
        piPolicyChangeTask = nil
        stopPiModelsSubscription(clearModels: true)
        AgentPiModelRegistry.shared.clearAllDiscoveredModels()
        piManagedRunsAllowDiscoveredExtensions = allow
        PiManagedRunExtensionDiscoverySettings.setAllowsDiscoveredExtensions(allow, defaults: piConnectionDefaults)
        refreshAgentAvailability()

        let shouldRestartDiscovery = isPiConnected || piConnectionDefaults.bool(forKey: "PiCLIConnected")
        let pollingService = piModelPollingService
        piPolicyChangeTask = Task { @MainActor [weak self, pollingService, shouldRestartDiscovery, allow] in
            await pollingService.resetModelDiscoveryStateForLaunchPolicyChange()
            guard let self,
                  !Task.isCancelled,
                  piManagedRunsAllowDiscoveredExtensions == allow
            else { return }
            piPolicyChangeTask = nil
            if shouldRestartDiscovery {
                startPiAvailabilityPreflightIfNeeded(workspacePath: nil)
            }
        }
    }

    func testPiConnection() async throws -> Bool {
        let collector = CLIProcessLogCollector()
        collector.append("pi RPC connection test started")
        piLogCollector = collector

        collector.append("Refreshing login-shell environment cache")
        await CLIEnvironmentCache.shared.invalidate()
        collector.append("Starting pi RPC model discovery preflight")

        do {
            let didConnect = try await refreshPiAvailabilityFromModelDiscovery(
                workspacePath: nil,
                collector: collector
            )
            guard didConnect else {
                throw AIProviderError.invalidConfiguration(detail: "pi RPC preflight completed but no model metadata was discovered.")
            }
            collector.append("pi RPC marked as connected")
            piLogCollector = nil
            startPiModelsSubscriptionIfNeeded(workspacePath: nil)
            return true
        } catch {
            collector.append("Connection test threw error: \(error.localizedDescription)")
            let finalMessage = friendlyPiMessage(for: error)
            stopPiModelsSubscription(clearModels: true)
            applyPiDisconnected(errorMessage: finalMessage)
            collector.append("User guidance: \(finalMessage)")
            throw error
        }
    }

    func refreshPiModelCatalogIfConnected(workspacePath: String? = nil) {
        guard isPiConnected || piConnectionDefaults.bool(forKey: "PiCLIConnected") else { return }
        guard piPreflightTask == nil else { return }
        piPreflightTask = Task { [weak self, workspacePath] in
            guard let self else { return }
            do {
                let didConnect = try await refreshPiAvailabilityFromModelDiscovery(
                    workspacePath: workspacePath,
                    collector: nil
                )
                if didConnect {
                    startPiModelsSubscriptionIfNeeded(workspacePath: workspacePath)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    stopPiModelsSubscription(clearModels: true)
                    applyPiDisconnected(errorMessage: friendlyPiMessage(for: error))
                }
            }
            await MainActor.run { [weak self] in self?.piPreflightTask = nil }
        }
    }

    func disconnectPi() {
        stopPiModelsSubscription(clearModels: true)
        piPreflightTask?.cancel()
        piPreflightTask = nil
        applyPiDisconnected(errorMessage: nil)
    }

    func hasPiTrace() -> Bool {
        piLogCollector?.isEmpty == false
    }

    func dumpPiTrace() throws -> URL {
        guard let collector = piLogCollector else {
            throw CLIProcessLogCollectorError.noEntries
        }
        collector.append("Exporting trace to Downloads folder")
        let exportDate = Date()
        let url = try collector.writeMarkdownToDownloads(
            baseFilename: "RepoPrompt-PiTrace",
            title: "pi RPC Connection Trace",
            timestamp: exportDate
        )
        collector.append("Trace exported to \(url.lastPathComponent)")
        return url
    }

    func applyCachedPiAvailabilityIfPresent() -> Bool {
        guard let cached = AgentPiModelRegistry.shared.cachedSnapshot(), !cached.options.isEmpty else { return false }
        applyPiConnected()
        applyPiModelSnapshot(PiModelPollingService.Snapshot(models: cached, fetchedAt: Date()))
        return true
    }

    func startPiAvailabilityPreflightIfNeeded(workspacePath: String?) {
        guard piPreflightTask == nil else { return }
        piPreflightTask = Task { [weak self, workspacePath] in
            guard let self else { return }
            let didConnect: Bool
            do {
                didConnect = try await refreshPiAvailabilityFromModelDiscovery(
                    workspacePath: workspacePath,
                    collector: nil
                )
            } catch {
                didConnect = false
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    stopPiModelsSubscription(clearModels: true)
                    applyPiDisconnected(errorMessage: friendlyPiMessage(for: error))
                }
            }
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in self?.piPreflightTask = nil }
                return
            }
            if didConnect {
                startPiModelsSubscriptionIfNeeded(workspacePath: workspacePath)
            }
            await MainActor.run { [weak self] in self?.piPreflightTask = nil }
        }
    }

    @discardableResult
    func refreshPiAvailabilityFromModelDiscovery(
        workspacePath: String?,
        collector: CLIProcessLogCollector?
    ) async throws -> Bool {
        let snapshot = try await piModelPollingService.discoverOnce(workspacePath: workspacePath)
        guard let snapshot else {
            applyPiDisconnected(errorMessage: "pi did not return any model options from its configured providers.")
            return false
        }
        collector?.append("Discovered \(snapshot.models.options.count) pi model option(s)")
        applyPiConnected()
        applyPiModelSnapshot(snapshot)
        return true
    }

    func startPiModelsSubscriptionIfNeeded(workspacePath: String?) {
        let canonicalWorkspacePath = AgentPiModelRegistry.canonicalWorkspacePath(workspacePath)
        if piModelsTask != nil {
            guard piModelsSubscribedWorkspacePath != canonicalWorkspacePath else { return }
            stopPiModelsSubscription()
        }
        piModelsSubscribedWorkspacePath = canonicalWorkspacePath
        let pollingService = piModelPollingService
        piModelsTask = Task { [weak self, pollingService, canonicalWorkspacePath] in
            let stream = await pollingService.subscribe(workspacePath: canonicalWorkspacePath)
            for await event in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    switch event {
                    case let .snapshot(snapshot):
                        applyPiConnected()
                        applyPiModelSnapshot(snapshot)
                    case let .failure(failure):
                        applyPiDisconnected(errorMessage: failure.message)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard self?.piModelsSubscribedWorkspacePath == canonicalWorkspacePath else { return }
                self?.piModelsTask = nil
                self?.piModelsSubscribedWorkspacePath = nil
            }
        }
    }

    func stopPiModelsSubscription(clearModels: Bool = false) {
        piModelsTask?.cancel()
        piModelsTask = nil
        piModelsSubscribedWorkspacePath = nil
        if clearModels {
            availablePiModelOptions = []
        }
    }

    func applyPiModelSnapshot(_ snapshot: PiModelPollingService.Snapshot) {
        availablePiModelOptions = snapshot.models.options
        Task { await updateAvailableModels() }
    }

    func applyPiConnected() {
        piError = nil
        isPiConnected = true
        piConnectionDefaults.set(true, forKey: "PiCLIConnected")
        NotificationCenter.default.post(name: .piConnectionChanged, object: nil)
    }

    func applyPiDisconnected(errorMessage: String?) {
        piError = errorMessage
        isPiConnected = false
        availablePiModelOptions = []
        piConnectionDefaults.set(false, forKey: "PiCLIConnected")
        NotificationCenter.default.post(name: .piConnectionChanged, object: nil)
        Task { await updateAvailableModels() }
    }

    func friendlyPiMessage(for error: Error) -> String {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case let .invalidConfiguration(detail):
                return detail
            case let .apiError(source):
                return source?.localizedDescription ?? "Unknown pi RPC error"
            default:
                return error.localizedDescription
            }
        }
        if let clientError = error as? PiRPCClient.ClientError {
            switch clientError {
            case let .executableUnavailable(message):
                return message
            case let .requestTimedOut(_, command):
                return "pi RPC timed out while handling `\(command)`. Check that `pi --mode rpc` can start and that pi is authenticated."
            case let .invalidResponse(message),
                 let .requestFailed(message),
                 let .transportClosed(message),
                 let .inputWriteFailed(message),
                 let .readerSetupFailed(message):
                return message
            case .processNotRunning:
                return "pi RPC process is not running."
            }
        }
        let message = error.localizedDescription
        let lowered = message.lowercased()
        if lowered.contains("not installed") || lowered.contains("no such file") || lowered.contains("command not found") || lowered.contains("not found") {
            return "pi executable was not found. Install pi and ensure `pi` is available on PATH."
        }
        if lowered.contains("permission denied") || lowered.contains("not runnable") || lowered.contains("not executable") {
            return "Permission denied. Ensure the `pi` executable is runnable."
        }
        if lowered.contains("unauthorized") || lowered.contains("not authenticated") || lowered.contains("login") || lowered.contains("auth") {
            return "pi is not authenticated. Complete pi's normal authentication flow, then try again."
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return "pi RPC did not respond before the timeout. Check that `pi --mode rpc` can start from Terminal."
        }
        return message
    }
}
