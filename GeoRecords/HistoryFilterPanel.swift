//
//  HistoryFilterPanel.swift
//  GeoRecords
//
//  The History filters behind the bar's filter button: a sheet on a phone, a
//  popover on wide layouts. The type and the source are pulldowns and the time
//  frame the segmented control, all in the Regions tab's grey rounded style; the
//  at-home rows a switch. Changes apply live behind the panel; Reset restores the
//  defaults.
//

import SwiftUI

struct HistoryFilterPanel: View {
    @Bindable var state: HistoryTabState
    let types: [String]
    let timeFrames: [String]
    let isRegionType: (String) -> Bool
    @Environment(\.dismiss) private var dismiss

    private var isRegionTypeSelected: Bool {
        isRegionType(state.typeFilter)
    }

    private var isDefault: Bool {
        state.typeFilter == "All Types" && state.source == .all
            && state.timeFrameFilter == "All Timeframes" && !state.includeHome
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Reset") { reset() }
                    .disabled(isDefault)
                Spacer()
                Text("Filter History")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Type") {
                        StyledPulldown(title: "Type", selection: $state.typeFilter, options: types) {
                            $0 == "All Types" ? "All types" : $0
                        }
                    }
                    section("Source") {
                        StyledPulldown(title: "Source", selection: $state.source, options: HistorySourceFilter.menuOrder) {
                            $0 == .all ? "All sources" : $0.title
                        }
                    }
                    section("Time frame") {
                        // Region visits have no timeframe variations
                        StyledSegmentedPicker(selection: $state.timeFrameFilter, options: timeFrames) {
                            $0 == "All Timeframes" ? "All" : $0
                        }
                        .disabled(isRegionTypeSelected)
                        .opacity(isRegionTypeSelected ? 0.5 : 1)
                    }
                    Toggle(isOn: $state.includeHome) {
                        Label("Include records set at home", systemImage: "house")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemGroupedBackground)))
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .frame(idealWidth: 360, idealHeight: 400)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func reset() {
        state.typeFilter = "All Types"
        state.source = .all
        state.timeFrameFilter = "All Timeframes"
        state.includeHome = false
    }
}
