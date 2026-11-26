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
/// how the Fastest lists rank and which of them show, measuring latency and
/// throughput, and the menu-bar icon.
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
    /// The Measure section: the run in flight, and when each last finished.
    @Published private(set) var measure = MeasureState()

    private let onIconStyle: () -> Void
    private let preview: (App.IconStyle) -> NSImage
    private let measureState: () -> MeasureState
    let startMeasurement: (MeasureKind) -> Void
    let cancelMeasurement: () -> Void

    /// `onIconStyle` redraws the bar after a new icon is stored; `preview`
    /// draws an icon as the bar would show it now. `measureState` reads the
    /// measurements as they stand; the other two start one and cancel it.
    init(onIconStyle: @escaping () -> Void, preview: @escaping (App.IconStyle) -> NSImage,
         measureState: @escaping () -> MeasureState,
         startMeasurement: @escaping (MeasureKind) -> Void, cancelMeasurement: @escaping () -> Void) {
        self.onIconStyle = onIconStyle
        self.preview = preview
        self.measureState = measureState
        self.startMeasurement = startMeasurement
        self.cancelMeasurement = cancelMeasurement
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
        refreshMeasure()
    }

    /// The app calls this whenever a measurement starts, moves or ends, and
    /// after each poll. Published only on a change, so an idle window is not
    /// redrawn every five seconds.
    func refreshMeasure() {
        let next = measureState()
        if next != measure { measure = next }
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
                PreferencesNote("Which Fastest submenus show, and how each orders its cities.")
            }
            Section {
                MeasureRow(kind: .latency, model: model)
                MeasureRow(kind: .throughput, model: model)
            } header: {
                Text("Measure")
            } footer: {
                PreferencesNote("Nothing is measured until you click one of these. Latency pings every city and takes a few seconds. Throughput connects through each city in turn, about 6–7 minutes, moving your connection from city to city; when it ends or you cancel, your relay and connection go back to how they were.")
            }
            Section("Menu Bar Icon") {
                IconTilePicker(model.iconChoices, selection: $model.iconStyle)
            }
        }
    }
}

/// One row of Preferences ▸ Measure. Idle: its name, when it last ran, and
/// its button. Running: what it is doing, a progress bar, and Cancel.
///
/// Both states are two lines of the same fixed height. A grouped form does
/// not re-measure a row whose content grows, so a taller running state
/// spilled over the row's edges.
private struct MeasureRow: View {
    let kind: MeasureKind
    @ObservedObject var model: PreferencesModel

    private var title: String { kind == .latency ? "Latency" : "Throughput" }
    private var buttonTitle: String { kind == .latency ? "Measure Latency Now" : "Measure Throughput Now" }
    private static let height: CGFloat = 36
    private static let secondLineHeight: CGFloat = 14

    var body: some View {
        HStack(spacing: 12) {
            if let activity = model.measure.activity, activity.kind == kind {
                // The throughput bar is an estimate that moves with the clock
                // between cities, so it redraws on a timer, not only on news.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    running(measureProgress(activity, now: context.date))
                }
                Button("Cancel") { model.cancelMeasurement() }
                    .disabled(!activity.canCancel)
            } else {
                lines(title) {
                    Text(model.measure.detail(kind, now: Date()))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Button(buttonTitle) { model.startMeasurement(kind) }
                    .disabled(!model.measure.canStart(kind))
            }
        }
        .frame(height: Self.height)
    }

    private func running(_ progress: MeasureProgress) -> some View {
        lines(progress.label) {
            Group {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .animation(.linear(duration: 0.5), value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)   // no estimate: cancelling, restoring
                }
            }
            .controlSize(.small)
            .accessibilityLabel(title)
        }
    }

    private func lines<Second: View>(_ first: String, @ViewBuilder second: () -> Second) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(first).lineLimit(1)
            second().frame(height: Self.secondLineHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
