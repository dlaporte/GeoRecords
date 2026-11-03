//
//  PhotoPromptTitleTests.swift
//  GeoRecordsTests
//

import Testing
@testable import GeoRecords

// Region records carry the stored type name "New Continent"; the photo prompt
// once read "🎉 New New Continent Record!" on a tester's phone
struct PhotoPromptTitleTests {

    @Test func regionTypesDropTheStoredNewPrefix() async throws {
        #expect(PhotoPicker.title(forRecordType: "New Continent") == "🎉 New Continent Record!")
        #expect(PhotoPicker.title(forRecordType: "New State") == "🎉 New State Record!")
        #expect(PhotoPicker.title(forRecordType: "New Country") == "🎉 New Country Record!")
    }

    @Test func recordTypesKeepTheirName() async throws {
        #expect(PhotoPicker.title(forRecordType: "Furthest North") == "🎉 New Furthest North Record!")
        #expect(PhotoPicker.title(forRecordType: "Furthest from Home") == "🎉 New Furthest from Home Record!")
    }
}
