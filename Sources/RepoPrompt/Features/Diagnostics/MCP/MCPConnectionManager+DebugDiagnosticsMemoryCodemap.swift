// MARK: - DEBUG Memory and CodeMap Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugLargeWorkspaceMemoryPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                let action = debugString(arguments, "action")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? "snapshot"
                let sampler = DebugProcessMemorySampler.shared

                let response: DebugProcessMemorySampler.DebugMemorySamplerResponse
                switch action {
                case "start":
                    let intervalMS: Int
                    switch debugBoundedInt(arguments, "interval_ms", defaultValue: 100, range: 50 ... 5000) {
                    case let .value(parsed), let .defaulted(parsed):
                        intervalMS = parsed
                    case .invalid:
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`interval_ms` must be an integer between 50 and 5000.")
                    }
                    let label = debugString(arguments, "label")?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let reset = debugBool(arguments, "reset") ?? false
                    response = await sampler.start(
                        label: (label?.isEmpty == false ? label : nil) ?? "large-workspace-memory",
                        intervalMS: intervalMS,
                        reset: reset
                    )
                case "mark":
                    guard let mark = debugString(arguments, "mark")?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !mark.isEmpty
                    else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`mark` must be a non-empty string for action `mark`.")
                    }
                    response = await sampler.mark(mark)
                case "stop":
                    let settleSeconds = debugDouble(arguments, "settle_seconds") ?? 0
                    guard settleSeconds.isFinite, settleSeconds >= 0, settleSeconds <= 300 else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`settle_seconds` must be a number between 0 and 300.")
                    }
                    response = await sampler.stop(settleSeconds: settleSeconds)
                case "snapshot":
                    let limit: Int
                    switch debugBoundedInt(arguments, "limit", defaultValue: 50, range: 1 ... 1000) {
                    case let .value(parsed), let .defaulted(parsed):
                        limit = parsed
                    case .invalid:
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
                    }
                    response = await sampler.snapshot(limit: limit)
                case "current":
                    let limit: Int
                    switch debugBoundedInt(arguments, "limit", defaultValue: 50, range: 1 ... 1000) {
                    case let .value(parsed), let .defaulted(parsed):
                        limit = parsed
                    case .invalid:
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
                    }
                    response = await sampler.current(limit: limit)
                case "reset":
                    response = await sampler.reset()
                default:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "Unknown `large_workspace_memory` action: \(action).")
                }

                switch response {
                case var .payload(payload):
                    payload["op"] = op
                    payload["action"] = action
                    return debugDiagnosticsResult(payload)
                case let .error(code, message):
                    return debugDiagnosticsError(op: op, code: code, message: message)
                }
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`large_workspace_memory` is only available in DEBUG builds.")
            #endif
        }

        func debugCodemapMemoryCountersPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                let windowID: Int
                switch debugBoundedInt(arguments, "window_id", defaultValue: -1, range: -1 ... 100_000) {
                case let .value(parsed), let .defaulted(parsed):
                    windowID = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be an integer between -1 and 100000; values <= 0 or omission aggregate all windows.")
                }
                let includeWindows = debugBool(arguments, "include_windows") ?? true

                switch await Self.debugCollectCodemapMemoryCounters(op: op, windowID: windowID, includeWindows: includeWindows) {
                case let .payload(payload):
                    return debugDiagnosticsResult(payload)
                case let .error(code, message):
                    return debugDiagnosticsError(op: op, code: code, message: message)
                }
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`codemap_memory_counters` is only available in DEBUG builds.")
            #endif
        }

        private enum DebugCodemapMemoryCountersResult {
            case payload([String: Any])
            case error(code: String, message: String)
        }

        @MainActor
        private static func debugCollectCodemapMemoryCounters(
            op: String,
            windowID: Int,
            includeWindows: Bool
        ) async -> DebugCodemapMemoryCountersResult {
            let allWindows = WindowStatesManager.shared.allWindows
            let selectedWindows: [WindowState]
            if windowID > 0 {
                selectedWindows = allWindows.filter { $0.windowID == windowID }
                guard !selectedWindows.isEmpty else {
                    return .error(code: "no_window", message: "No RepoPrompt window matched window_id \(windowID).")
                }
            } else {
                selectedWindows = allWindows
            }

            var countersByWindow: [(window: WindowState, workspaceID: String, workspaceName: String, counters: WorkspaceCodemapMemoryCounters)] = []
            countersByWindow.reserveCapacity(selectedWindows.count)
            for window in selectedWindows {
                let workspace = window.workspaceManager.activeWorkspace
                let counters = await window.workspaceFilesViewModel.debugCodemapMemoryCounters()
                countersByWindow.append((
                    window: window,
                    workspaceID: workspace?.id.uuidString ?? "<none>",
                    workspaceName: workspace?.name ?? "<none>",
                    counters: counters
                ))
            }

            let totals = countersByWindow.reduce(Self.debugEmptyCodemapMemoryCounters()) { partial, row in
                Self.debugAddCodemapMemoryCounters(partial, row.counters)
            }
            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "scope": windowID > 0 ? "window_id" : "all_windows",
                "window_count": countersByWindow.count,
                "totals": debugCodemapCountersDictionary(totals)
            ]
            if windowID > 0 {
                payload["window_id"] = windowID
            }
            if includeWindows {
                payload["windows"] = countersByWindow.map { row in
                    [
                        "window_id": row.window.windowID,
                        "workspace_id": row.workspaceID,
                        "workspace_name": row.workspaceName,
                        "counters": debugCodemapCountersDictionary(row.counters)
                    ] as [String: Any]
                }
            }
            return .payload(payload)
        }

        private static func debugEmptyCodemapMemoryCounters() -> WorkspaceCodemapMemoryCounters {
            WorkspaceCodemapMemoryCounters(
                compatibilitySnapshotCount: 0,
                compatibilitySnapshotRootCount: 0,
                modernSessionCount: 0,
                modernDemandCount: 0,
                retainedDemandCount: 0,
                internalRetainCount: 0,
                readyBundleCount: 0,
                cleanupFlightCount: 0,
                setupTaskCount: 0,
                pendingDemandCount: 0,
                activeDemandTaskCount: 0
            )
        }

        private static func debugAddCodemapMemoryCounters(
            _ lhs: WorkspaceCodemapMemoryCounters,
            _ rhs: WorkspaceCodemapMemoryCounters
        ) -> WorkspaceCodemapMemoryCounters {
            WorkspaceCodemapMemoryCounters(
                compatibilitySnapshotCount: lhs.compatibilitySnapshotCount + rhs.compatibilitySnapshotCount,
                compatibilitySnapshotRootCount: lhs.compatibilitySnapshotRootCount + rhs.compatibilitySnapshotRootCount,
                modernSessionCount: lhs.modernSessionCount + rhs.modernSessionCount,
                modernDemandCount: lhs.modernDemandCount + rhs.modernDemandCount,
                retainedDemandCount: lhs.retainedDemandCount + rhs.retainedDemandCount,
                internalRetainCount: lhs.internalRetainCount + rhs.internalRetainCount,
                readyBundleCount: lhs.readyBundleCount + rhs.readyBundleCount,
                cleanupFlightCount: lhs.cleanupFlightCount + rhs.cleanupFlightCount,
                setupTaskCount: lhs.setupTaskCount + rhs.setupTaskCount,
                pendingDemandCount: lhs.pendingDemandCount + rhs.pendingDemandCount,
                activeDemandTaskCount: lhs.activeDemandTaskCount + rhs.activeDemandTaskCount
            )
        }

        private static func debugCodemapCountersDictionary(_ counters: WorkspaceCodemapMemoryCounters) -> [String: Any] {
            [
                "compatibility_snapshots": counters.compatibilitySnapshotCount,
                "compatibility_snapshot_roots": counters.compatibilitySnapshotRootCount,
                "modern_sessions": counters.modernSessionCount,
                "modern_demands": counters.modernDemandCount,
                "retained_demands": counters.retainedDemandCount,
                "internal_retains": counters.internalRetainCount,
                "ready_bundles": counters.readyBundleCount,
                "cleanup_flights": counters.cleanupFlightCount,
                "setup_tasks": counters.setupTaskCount,
                "pending_demands": counters.pendingDemandCount,
                "active_demand_tasks": counters.activeDemandTaskCount
            ]
        }
    }
#endif
