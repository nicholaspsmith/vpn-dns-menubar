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
        Mullvad account:    8991497502551539
        Expires at:         2026-10-02 14:44:31 -04:00
        Device name:        Fair Sheep
        """
        XCTAssertEqual(parseMullvadDeviceName(raw), "Fair Sheep")
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
        XCTAssertEqual(parseMullvadDeviceName("Device name:   Proper Gecko   \n"), "Proper Gecko")
    }

    func testAccountNumberIsNotConfusedForTheName() {
        let raw = """
        Mullvad account:    8991497502551539
        Device name:        Clear Turtle
        """
        XCTAssertEqual(parseMullvadDeviceName(raw), "Clear Turtle")
    }
}
