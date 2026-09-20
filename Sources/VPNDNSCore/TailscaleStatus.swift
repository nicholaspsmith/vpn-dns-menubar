// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// First `"BackendState": "X"` value from `tailscale status --json`, else "Unknown".
public func parseTailscaleBackend(_ json: String) -> String {
    for line in json.split(separator: "\n") {
        guard line.contains("\"BackendState\"") else { continue }
        let parts = line.split(separator: "\"")
        // ... "BackendState" : "Running" ,  -> tokens: [.., BackendState, .., Running, ..]
        if let idx = parts.firstIndex(of: "BackendState"), idx + 2 < parts.count {
            return String(parts[idx + 2])
        }
    }
    return "Unknown"
}

/// First `"CorpDNS": true|false` from `tailscale debug prefs`, else false.
public func parseCorpDNS(_ prefs: String) -> Bool {
    for line in prefs.split(separator: "\n") where line.contains("\"CorpDNS\"") {
        return line.contains("true")
    }
    return false
}
