import Foundation

/// Serializes workspace-context store integration tests that mutate shared debug hooks,
/// caches, and search/indexing surfaces. These tests lived in one XCTestCase class
/// historically; sharding them for XCTest discovery stability must not make them
/// run concurrently.
enum WorkspaceContextStoreTestSerialExecutor {
    static let lock = NSLock()
}
