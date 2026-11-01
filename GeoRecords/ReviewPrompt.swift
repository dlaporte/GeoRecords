//
//  ReviewPrompt.swift
//  GeoRecords
//
//  When to ask for an App Store review: after the second lifetime record the
//  user actually beat (first-ever rows, imports and region rows never count),
//  and only once.
//

import Foundation

enum ReviewPrompt {
    static let threshold = 2

    static func shouldRequest(beatenLifetimeCount: Int, alreadyRequested: Bool) -> Bool {
        !alreadyRequested && beatenLifetimeCount >= threshold
    }
}
