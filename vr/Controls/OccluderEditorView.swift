//
//  OccluderEditorView.swift
//  vr
//
//  The panel for marking out real objects the car should disappear behind.
//

import SwiftUI

/// Sits over the camera while the player marks out real furniture.
///
/// The panel is deliberately plain about what this is: hand-placed boxes, not
/// a scan. On an iPhone without a LiDAR scanner nothing can work out the shape
/// of a sofa, and pretending otherwise would just make the result look broken.
struct OccluderEditorView: View {

    @Bindable var model: ARExperienceModel
    @State private var dimension: OccluderDimension = .width

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            panel
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var panel: some View {
        VStack(spacing: 12) {
            header

            if model.selectedOccluder != nil {
                sizing
            } else {
                Text(model.occluderCount == 0
                     ? "Point at a real object — a chair leg, a sofa, a box — and add a shape roughly its size."
                     : "Tap a box to adjust it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
            }

            buttons

            Text("Hand-placed and approximate. This iPhone can't work out the shape of your furniture on its own.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }

    private var header: some View {
        HStack {
            Label("Occluders", systemImage: "cube.transparent")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(model.occluderCount == 1 ? "1 shape" : "\(model.occluderCount) shapes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sizing: some View {
        VStack(spacing: 8) {
            Picker("Measurement", selection: $dimension) {
                ForEach(OccluderDimension.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Slider(value: valueBinding, in: Double(dimension.range.lowerBound)...Double(dimension.range.upperBound))
                Text(dimension.formatted(currentValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .frame(height: 62)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: model.addOccluder) {
                Label("Add", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive, action: model.deleteOccluder) {
                Image(systemName: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedOccluder == nil)
            .accessibilityLabel("Delete the selected shape")

            Button(action: model.clearOccluders) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.occluderCount == 0)
            .accessibilityLabel("Remove every shape")

            Button("Done") { model.setOccluderEditing(false) }
                .buttonStyle(.bordered)
                .fontWeight(.semibold)
        }
        .controlSize(.large)
    }

    private var currentValue: Float {
        model.selectedOccluder?[dimension] ?? dimension.range.lowerBound
    }

    private var valueBinding: Binding<Double> {
        Binding(
            get: { Double(currentValue) },
            set: { model.setOccluder(Float($0), for: dimension) }
        )
    }
}
