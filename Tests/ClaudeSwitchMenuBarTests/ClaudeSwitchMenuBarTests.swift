import Foundation
import Testing
@testable import ClaudeSwitchMenuBar

@Test func decodesSequenceState() throws {
    let json = """
    {
      "activeAccountNumber": 2,
      "lastUpdated": "2026-04-02T20:00:00Z",
      "sequence": [1, 2],
      "accounts": {
        "1": { "email": "one@example.com" },
        "2": { "email": "two@example.com" }
      }
    }
    """

    let state = try JSONDecoder().decode(SequenceState.self, from: Data(json.utf8))
    #expect(state.activeAccountNumber == 2)
    #expect(state.sequence == [1, 2])
    #expect(state.accounts["2"]?.email == "two@example.com")
}
