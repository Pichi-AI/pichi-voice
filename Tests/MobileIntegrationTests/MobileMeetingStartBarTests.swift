import SwiftUI
import UIKit
import XCTest
@testable import PichiVoiceMobile

final class MobileMeetingStartBarTests: XCTestCase {
    func testLandscapePhoneUsesInlineControlsAndPortraitRestoresStack() {
        XCTAssertTrue(MobileMeetingStartBar.usesInlineLayout(idiom: .phone,
            verticalSizeClass: .compact, dynamicTypeSize: .large))
        XCTAssertFalse(MobileMeetingStartBar.usesInlineLayout(idiom: .phone,
            verticalSizeClass: .regular, dynamicTypeSize: .large))
        XCTAssertFalse(MobileMeetingStartBar.usesInlineLayout(idiom: .phone,
            verticalSizeClass: nil, dynamicTypeSize: .large))
    }

    func testTabletAndUnknownDevicesKeepExistingStackInEverySizeClass() {
        for idiom in [UIUserInterfaceIdiom.pad, .unspecified] {
            for sizeClass: UserInterfaceSizeClass? in [.compact, .regular, nil] {
                XCTAssertFalse(MobileMeetingStartBar.usesInlineLayout(idiom: idiom,
                    verticalSizeClass: sizeClass, dynamicTypeSize: .large))
            }
        }
    }

    func testLargerTextKeepsReadableStackedControls() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            XCTAssertFalse(MobileMeetingStartBar.usesInlineLayout(idiom: .phone,
                verticalSizeClass: .compact, dynamicTypeSize: size))
        }
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge] {
            XCTAssertTrue(MobileMeetingStartBar.usesInlineLayout(idiom: .phone,
                verticalSizeClass: .compact, dynamicTypeSize: size))
        }
    }
}
