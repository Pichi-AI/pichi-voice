import SwiftUI
import UIKit
import XCTest
@testable import PichiVoiceMobile

final class MobileMeetingStartBarTests: XCTestCase {
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
