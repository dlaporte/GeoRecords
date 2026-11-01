//
//  ReviewPromptTests.swift
//  GeoRecordsTests
//

import Testing
@testable import GeoRecords

struct ReviewPromptTests {
    @Test func reviewIsRequestedOnceAfterTheSecondBeatenLifetimeRecord() async throws {
        #expect(ReviewPrompt.shouldRequest(beatenLifetimeCount: 1, alreadyRequested: false) == false)
        #expect(ReviewPrompt.shouldRequest(beatenLifetimeCount: 2, alreadyRequested: false) == true)
        #expect(ReviewPrompt.shouldRequest(beatenLifetimeCount: 5, alreadyRequested: true) == false)
    }
}
