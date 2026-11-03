// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import StatusItemKit
import SwiftUI
import VPNDNSCore

/// VPN & DNS's Preferences window (menu ▸ Preferences…, ⌘,): Start at Login,
/// how the Fastest lists rank and which of them show, and the menu-bar icon.
/// It replaced the Settings and Icon submenus, as in Mac Daddy and the rest
/// of Menumon; the window and form are StatusItemKit's shared
/// `PreferencesPane` and `PreferencesForm`. Connecting, disconnecting and
/// the relay picks stay in the menu.
final class PreferencesModel: ObservableObject {
    @Published var iconStyle: App.IconStyle {
        didSet { if iconStyle != oldValue { App.IconStyle.current = iconStyle; onIconStyle() } }
    }
    @Published var rankMode: RankMode {
        didSet { if rankMode != oldValue { App.RankModeSetting.current = rankMode } }
    }
    @Published private(set) var hidden: Set<FastList>
    /// Each icon as it looks in the bar right now.
    @Published private(set) var iconChoices: [IconTilePicker<App.IconStyle>.Choice] = []

    private let onIconStyle: () -> Void
    private let preview: (App.IconStyle) -> NSImage

    /// `onIconStyle` redraws the bar after a new icon is stored; `preview`
    /// draws an icon as the bar would show it now.
    init(onIconStyle: @escaping () -> Void, preview: @escaping (App.IconStyle) -> NSImage) {
        self.onIconStyle = onIconStyle
        self.preview = preview
        iconStyle = App.IconStyle.current
        rankMode = App.RankModeSetting.current
        hidden = App.HiddenFastLists.current
        refresh()
    }

    /// Re-reads the stored choices and redraws the previews in the current
    /// connection state.
    func refresh() {
        iconStyle = App.IconStyle.current
        rankMode = App.RankModeSetting.current
        hidden = App.HiddenFastLists.current
        iconChoices = App.IconStyle.allCases.map { .init(id: $0, title: $0.title, image: preview($0)) }
    }

    func isShown(_ list: FastList) -> Bool { !hidden.contains(list) }

    func setShown(_ list: FastList, _ shown: Bool) {
        var next = App.HiddenFastLists.current
        if shown { next.remove(list) } else { next.insert(list) }
        App.HiddenFastLists.current = next
        hidden = next
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        PreferencesForm {
            Section("General") {
                StartAtLoginToggle()
            }
            Section {
                Picker("Rank by", selection: $model.rankMode) {
                    ForEach(RankMode.allCases, id: \.self) { Text($0.preferencesTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(FastList.allCases, id: \.self) { list in
                    Toggle("Fastest \(list.shortName)", isOn: Binding(get: { model.isShown(list) },
                                                                    set: { model.setShown(list, $0) }))
                }
            } header: {
                Text("Fastest Lists")
            } footer: {
                PreferencesNote("Which Fastest submenus show under Mullvad, and how each orders its cities. Latency and throughput are only measured when you pick them under Measure in the menu.")
            }
            Section("Menu Bar Icon") {
                IconTilePicker(model.iconChoices, selection: $model.iconStyle)
            }
        }
    }
}

extension RankMode {
    /// The segment's label: the menu titles less "Rank by".
    var preferencesTitle: String {
        switch self {
        case .latency: return "Latency"
        case .throughput: return "Throughput"
        }
    }
}

extension PreferencesPane {
    /// VPN & DNS's window, re-reading its model each time it is shown.
    static func vpnDNS(model: PreferencesModel) -> PreferencesPane {
        let pane = PreferencesPane(appName: "VPN & DNS") { PreferencesView(model: model) }
        pane.onShow = { model.refresh() }
        return pane
    }
}
