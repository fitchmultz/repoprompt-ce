import Foundation
@testable import RepoPrompt
import XCTest

final class PiAgentSessionPersistenceTests: XCTestCase {
    func testPiSessionFileRoundTripsThroughAgentSessionCoding() throws {
        let session = AgentSession(
            providerSessionID: "pi-session-id",
            piSessionFile: "/tmp/pi-session.jsonl"
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)

        XCTAssertEqual(decoded.providerSessionID, "pi-session-id")
        XCTAssertEqual(decoded.piSessionFile, "/tmp/pi-session.jsonl")
    }
}
