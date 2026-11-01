//
//  CardinalFormattingTests.swift
//  GeoRecordsTests
//

import Testing
import CoreLocation
@testable import GeoRecords

struct CardinalFormattingTests {

    // Cards led with "-122.3321°" and no hemisphere
    @Test func recordValuesCarryAHemisphere() async throws {
        #expect(FormatUtils.formatValue(value: 69.6492, recordType: RecordType.north.rawValue, unitSystem: .imperial) == "69.6492° N")
        #expect(FormatUtils.formatValue(value: -33.8688, recordType: RecordType.south.rawValue, unitSystem: .imperial) == "33.8688° S")
        #expect(FormatUtils.formatValue(value: -71.0589, recordType: RecordType.west.rawValue, unitSystem: .imperial) == "71.0589° W")
        #expect(FormatUtils.formatValue(value: 139.6917, recordType: RecordType.east.rawValue, unitSystem: .imperial) == "139.6917° E")
    }

    // Siri reads "N" as a letter; it needs words
    @Test func spokenValuesReadNaturally() async throws {
        #expect(FormatUtils.spokenValue(69.6492, recordType: RecordType.north.rawValue, unitSystem: .imperial) == "69.65 degrees north")
        #expect(FormatUtils.spokenValue(-71.0589, recordType: RecordType.west.rawValue, unitSystem: .imperial) == "71.06 degrees west")
        #expect(FormatUtils.spokenValue(304.8, recordType: RecordType.up.rawValue, unitSystem: .imperial) == "1,000 feet")
        #expect(FormatUtils.spokenValue(482_803, recordType: RecordType.fromHome.rawValue, unitSystem: .imperial) == "300 miles")
        #expect(FormatUtils.spokenValue(12_000, recordType: RecordType.fromHome.rawValue, unitSystem: .metric) == "12 kilometers")
    }

    @Test func discoveredValuesMatchRecordValues() async throws {
        let text = FormatUtils.formatDiscoveredRecordValue(recordType: RecordType.north.rawValue, value: 69.6492, altitude: 0, unitSystem: .imperial)
        #expect(text == "69.6492° N")
        let west = FormatUtils.formatDiscoveredRecordValue(recordType: RecordType.west.rawValue, value: -71.0589, altitude: 0, unitSystem: .imperial, coordinatePrecision: 2)
        #expect(west == "71.06° W")
    }
}
