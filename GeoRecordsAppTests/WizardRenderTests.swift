//
//  WizardRenderTests.swift
//  GeoRecordsTests
//
//  Renders the setup wizard steps and the import wizard step strip at the folded
//  iPhone Duo's sizes and an iPhone's, attaching PNGs for eyeballing (export with
//  `xcrun xcresulttool export attachments`). The Duo renders must show no "…";
//  the iPhone renders must match the layout before WizardDensity existed.
//

import XCTest
import SwiftUI
@testable import GeoRecords

@MainActor
final class WizardRenderTests: XCTestCase {

    /// The folded Duo's 382×644 window leaves about 486 pt for a wizard page;
    /// an iPhone 16 Pro leaves about 601
    private let duoPage = CGSize(width: 382, height: 486)
    private let phonePage = CGSize(width: 393, height: 601)

    func testWelcomeStepAtDuoAndPhoneSizes() {
        attach(FitToHeight { WelcomeStepView() }, size: duoPage, name: "welcome-duo")
        attach(FitToHeight { WelcomeStepView() }, size: phonePage, name: "welcome-phone")
    }

    func testNotificationsStepAtDuoAndPhoneSizes() {
        attach(FitToHeight { NotificationsStepView(notificationsEnabled: .constant(true)) },
               size: duoPage, name: "notifications-duo")
        attach(FitToHeight { NotificationsStepView(notificationsEnabled: .constant(true)) },
               size: phonePage, name: "notifications-phone")
    }

    func testPhotoImportStepAtDuoAndPhoneSizes() {
        let scanner = PhotoLibraryScanner()
        attach(FitToHeight {
            PhotoImportStepView(wantPhotoImport: .constant(true), photoScanner: scanner, showPermissionAlert: .constant(false))
        }, size: duoPage, name: "photo-import-duo")
        attach(FitToHeight {
            PhotoImportStepView(wantPhotoImport: .constant(true), photoScanner: scanner, showPermissionAlert: .constant(false))
        }, size: phonePage, name: "photo-import-phone")
    }

    func testStepStripAtPhoneAndPadWidths() {
        for (width, name) in [(382, "duo"), (393, "phone"), (834, "pad")] {
            let size = CGSize(width: width, height: 60)
            attach(WizardProgressIndicator(currentStep: .allTime), size: size, name: "strip-\(name)-lifetime")
            attach(WizardProgressIndicator(currentStep: .yearly), size: size, name: "strip-\(name)-past-years")
        }
    }
}
