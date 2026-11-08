import SwiftUI
import UIKit
import XCTest
@testable import PichiVoiceMobile

final class MobileMeetingStartBarTests: XCTestCase {
    func testDockedNavigationGapIsConfinedToPortraitPhone() {
        XCTAssertTrue(MobileMeetingStartBar.needsDockedNavigationGap(idiom: .phone, verticalSizeClass: .regular))
        XCTAssertFalse(MobileMeetingStartBar.needsDockedNavigationGap(idiom: .phone, verticalSizeClass: .compact))
        XCTAssertFalse(MobileMeetingStartBar.needsDockedNavigationGap(idiom: .phone, verticalSizeClass: nil))
        for sizeClass: UserInterfaceSizeClass? in [.regular, .compact, nil] {
            XCTAssertFalse(MobileMeetingStartBar.needsDockedNavigationGap(idiom: .pad, verticalSizeClass: sizeClass))
            XCTAssertFalse(MobileMeetingStartBar.needsDockedNavigationGap(idiom: .unspecified, verticalSizeClass: sizeClass))
        }
    }

    func testTabRowActionIsConfinedToVisibleHistoryRoot() {
        XCTAssertTrue(MobileMeetingStartBar.showsTabRowAction(showingRecordings: true,
            historyIsAtRoot: true, isCapturing: false, privateDataVisible: true))
        XCTAssertFalse(MobileMeetingStartBar.showsTabRowAction(showingRecordings: false,
            historyIsAtRoot: true, isCapturing: false, privateDataVisible: true))
        XCTAssertFalse(MobileMeetingStartBar.showsTabRowAction(showingRecordings: true,
            historyIsAtRoot: false, isCapturing: false, privateDataVisible: true))
        XCTAssertFalse(MobileMeetingStartBar.showsTabRowAction(showingRecordings: true,
            historyIsAtRoot: true, isCapturing: true, privateDataVisible: true))
        XCTAssertFalse(MobileMeetingStartBar.showsTabRowAction(showingRecordings: true,
            historyIsAtRoot: true, isCapturing: false, privateDataVisible: false))
    }

    func testLandscapePhoneFloatsAndPortraitKeepsDockedControl() {
        XCTAssertTrue(MobileMeetingStartBar.usesFloatingLayout(idiom: .phone,
            verticalSizeClass: .compact, dynamicTypeSize: .large))
        XCTAssertFalse(MobileMeetingStartBar.usesFloatingLayout(idiom: .phone,
            verticalSizeClass: .regular, dynamicTypeSize: .large))
        XCTAssertFalse(MobileMeetingStartBar.usesFloatingLayout(idiom: .phone,
            verticalSizeClass: nil, dynamicTypeSize: .large))
    }

    func testTabletAndUnknownDevicesKeepDockedControlInEverySizeClass() {
        for idiom in [UIUserInterfaceIdiom.pad, .unspecified] {
            for sizeClass: UserInterfaceSizeClass? in [.compact, .regular, nil] {
                XCTAssertFalse(MobileMeetingStartBar.usesFloatingLayout(idiom: idiom,
                    verticalSizeClass: sizeClass, dynamicTypeSize: .large))
            }
        }
    }

    func testLargerTextKeepsReadableDockedControl() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            XCTAssertFalse(MobileMeetingStartBar.usesFloatingLayout(idiom: .phone,
                verticalSizeClass: .compact, dynamicTypeSize: size))
        }
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge] {
            XCTAssertTrue(MobileMeetingStartBar.usesFloatingLayout(idiom: .phone,
                verticalSizeClass: .compact, dynamicTypeSize: size))
        }
    }
}
