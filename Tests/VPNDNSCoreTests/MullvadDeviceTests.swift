// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import VPNDNSCore

final class MullvadDeviceTests: XCTestCase {
    func testLoggedIn() {
        let raw = """
        Mullvad account:    1234567890123456
        Expires at:         2030-01-01 00:00:00 +00:00
        Device name:        Calm Lynx
        """
        XCTAssertEqual(parseMullvadDeviceName(raw), "Calm Lynx")
    }

    func testLoggedOut() {
        XCTAssertNil(parseMullvadDeviceName("Not logged in on any account\n"))
    }

    func testMissingLineEntirely() {
        XCTAssertNil(parseMullvadDeviceName(""))
    }

    func testEmptyValueIsNil() {
        XCTAssertNil(parseMullvadDeviceName("Device name:        \n"))
    }

    func testTrailingWhitespaceTrimmed() {
        XCTAssertEqual(parseMullvadDeviceName("Device name:   Eager Mole   \n"), "Eager Mole")
    }

    func testAccountNumberIsNotConfusedForTheName() {
        let raw = """
        Mullvad account:    1234567890123456
        Device name:        Deft Heron
        """
        XCTAssertEqual(parseMullvadDeviceName(raw), "Deft Heron")
    }
}
