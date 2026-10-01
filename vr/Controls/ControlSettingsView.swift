//
//  ControlSettingsView.swift
//  vr
//
//  Lets the player put the driving controls where their hands actually are.
//

import SwiftUI

/// Drag any control to move it, then size it. The preview is the real control
/// artwork at the real size, so what you arrange here is exactly what you get.
struct ControlSettingsView: View {

    @Bindable var settings: ControlSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selected: ControlKind = .handbrake
    @State private var dragOrigin: CGPoint?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                // The preview is the whole screen, scaled down to fit above the
                // panel. Anything else and a control dragged to the bottom of
                // the editor would not be at the bottom of the real screen.
                let screen = proxy.size
                let available = CGSize(width: proxy.size.width,
                                       height: max(proxy.size.height - panelHeight, 1))
                let scale = min(available.width / screen.width, available.height / screen.height)
                let canvas = CGSize(width: screen.width * scale, height: screen.height * scale)
                let frames = settings.layout.frames(in: screen)

                VStack(spacing: 0) {
                    ZStack {
                        backdrop
                        ZStack(alignment: .topLeading) {
                            Color.clear.frame(width: screen.width, height: screen.height)
                            ControlPadVisuals(steering: 0, pressed: [], frames: frames,
                                              isEnabled: true, showsShifter: isManual,
                                              highlighted: selected)
                                .allowsHitTesting(false)
                            ForEach(placeableControls) { kind in
                                if let frame = frames[kind] {
                                    dragHandle(kind: kind, frame: frame, screen: screen, scale: scale)
                                }
                            }
                        }
                        .frame(width: screen.width, height: screen.height)
                        .scaleEffect(scale)
                        .frame(width: canvas.width, height: canvas.height)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                                .frame(width: canvas.width, height: canvas.height)
                        )
                    }
                    .frame(height: available.height)
                    .clipped()

                    ScrollView { panel }
                        .frame(height: panelHeight)
                        .background(.regularMaterial)
                }
            }
            .background(Color.black)
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        withAnimation(.snappy) { settings.resetLayout() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private let panelHeight: CGFloat = 330

    private var isManual: Bool { settings.transmissionMode == .manual }

    /// The gear shift is only arrangeable when there are gears to choose, so
    /// nobody is asked to find a home for a control they will never see.
    private var placeableControls: [ControlKind] {
        ControlKind.allCases.filter { isManual || !$0.isManualOnly }
    }

    private var backdrop: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Text("Drag a control to move it")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 14)
            }
    }

    /// An invisible grab area over each control, in the preview's own space.
    private func dragHandle(kind: ControlKind, frame: CGRect,
                            screen: CGSize, scale: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: frame.width + 40, height: frame.height + 40)
            .position(x: frame.midX, y: frame.midY)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = CGPoint(x: frame.midX, y: frame.midY)
                            selected = kind
                            Haptics.light()
                        }
                        guard let origin = dragOrigin, screen.width > 0, screen.height > 0 else { return }
                        // The preview is scaled, but the gesture reports points
                        // in the scaled view's own coordinates, which already
                        // match the screen space the frames were built in.
                        let point = CGPoint(x: origin.x + value.translation.width,
                                            y: origin.y + value.translation.height)
                        settings.layout[kind].anchor = CGPoint(
                            x: min(max(point.x / screen.width, 0), 1),
                            y: min(max(point.y / screen.height, 0), 1)
                        )
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Control", selection: $selected) {
                ForEach(placeableControls) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.transmissionMode) { _, _ in
                // The shift buttons vanish with Automatic, so the panel cannot
                // be left sizing something that is no longer on screen.
                if selected.isManualOnly && !isManual { selected = .handbrake }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Size")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Slider(value: sizeBinding, in: 0.75...1.45, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tyre effects")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Tyre effects", selection: $settings.effectsQuality) {
                    ForEach(EffectsQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            smokeColors

            driving

            Toggle("Haptics", isOn: $settings.usesHaptics)
                .font(.subheadline)

            occlusion
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var smokeColors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drift Smoke")
                        .font(.subheadline.weight(.semibold))
                    Text("Soft trails from the rear tyres")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: -5) {
                    ForEach(Array(settings.smokeStyle.activeColors.enumerated()), id: \.offset) { _, smokeColor in
                        Circle()
                            .fill(smokeColor.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1))
                    }
                }
                .accessibilityHidden(true)
            }

            smokePreview

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(SmokeStyle.presets.enumerated()), id: \.offset) { _, preset in
                        Button {
                            settings.smokeStyle = preset.style
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(preset.style.activeColors[0].color)
                                    .frame(width: 11, height: 11)
                                Text(preset.name)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(settings.smokeStyle == preset.style
                                        ? Color.white.opacity(0.18) : Color.white.opacity(0.07),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                settings.smokeStyle == preset.style
                                    ? Color.white.opacity(0.65) : Color.white.opacity(0.12),
                                lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Picker("Smoke colors", selection: $settings.smokeStyle.colorCount) {
                ForEach(SmokeColorCount.allCases) { count in
                    Text(count.title).tag(count)
                }
            }
            .pickerStyle(.segmented)

            ForEach(0..<settings.smokeStyle.colorCount.rawValue, id: \.self) { index in
                ColorPicker(colorTitle(for: index), selection: smokeColorBinding(at: index), supportsOpacity: false)
                    .font(.subheadline)
            }

            Text(settings.smokeStyle.colorCount == .two
                 ? "Left and right tyres use different colors; their trails mix as you turn."
                 : settings.smokeStyle.colorCount == .three
                 ? "All three colors mingle naturally in both trails."
                 : "Both rear tyres use the same color.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .disabled(!settings.effectsQuality.showsSmoke)
        .opacity(settings.effectsQuality.showsSmoke ? 1 : 0.45)
    }

    private var smokePreview: some View {
        HStack(spacing: 4) {
            smokeCloud(colors: previewColors(for: 0))
            smokeCloud(colors: previewColors(for: 1))
        }
        .frame(height: 70)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.22)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(alignment: .bottom) {
            HStack {
                Text("LEFT TYRE")
                Spacer()
                Text("RIGHT TYRE")
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 20)
            .padding(.bottom, 7)
        }
        .accessibilityLabel("Preview of left and right drift smoke colors")
    }

    private func smokeCloud(colors: [SmokeColor]) -> some View {
        ZStack {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, smokeColor in
                Ellipse()
                    .fill(smokeColor.color.opacity(0.44))
                    .frame(width: 64, height: 28)
                    .blur(radius: 10)
                    .offset(x: (CGFloat(index) - CGFloat(colors.count - 1) / 2) * 16,
                            y: CGFloat(index % 2) * -7)
            }
            Ellipse()
                .fill(.white.opacity(0.12))
                .frame(width: 78, height: 20)
                .blur(radius: 13)
        }
        .frame(maxWidth: .infinity)
    }

    private func previewColors(for wheel: Int) -> [SmokeColor] {
        let colors = settings.smokeStyle.activeColors
        if settings.smokeStyle.colorCount == .two { return [colors[min(wheel, colors.count - 1)]] }
        return colors
    }

    private func colorTitle(for index: Int) -> String {
        if settings.smokeStyle.colorCount == .two {
            return index == 0 ? "Left tyre" : "Right tyre"
        }
        return "Color \(index + 1)"
    }

    private func smokeColorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: { settings.smokeStyle.color(at: index).color },
            set: { settings.smokeStyle.setColor(SmokeColor($0), at: index) }
        )
    }

    /// The gearbox and what the speedometer counts in.
    private var driving: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Instrument display")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Instrument display", selection: $settings.instrumentStyle) {
                    ForEach(InstrumentStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Choose a clean digital readout or a pair of classic dials.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Transmission")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Transmission", selection: $settings.transmissionMode) {
                    ForEach(TransmissionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(isManual
                     ? "You choose the gears with the + and − buttons. There's no clutch — the gearbox slips it for you when you pull away."
                     : "The car changes gear for you, and the brake still becomes reverse once you've stopped.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Speed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Speed", selection: $settings.speedUnit) {
                    ForEach(SpeedUnit.allCases) { Text($0.abbreviation).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("The speed of the full-size car being simulated, not of the model crossing your floor.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// What this iPhone can hide the car behind, stated plainly, and the switch
    /// for the hand-placed fallback.
    private var occlusion: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Going behind real things")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            capabilityRow(title: "Room scan",
                          detail: capabilities.sceneMeshSummary,
                          isAvailable: capabilities.hasSceneMesh)
            if capabilities.hasSceneMesh {
                Toggle("Use the room scan", isOn: $settings.usesRoomScanOcclusion)
                    .font(.subheadline)
                Text("Turn off if things lying on the floor disappear into it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            capabilityRow(title: "People",
                          detail: capabilities.peopleSummary,
                          isAvailable: capabilities.hasPeopleDepth)

            Toggle("Occluder tool", isOn: $settings.showsOccluderTool)
                .font(.subheadline)
            Text("Mark out real objects by hand, for the things a scan can't find.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func capabilityRow(title: String, detail: String, isAvailable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isAvailable ? Color.green : Color.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private let capabilities = OcclusionCapabilities.current

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.layout[selected].scale) },
            set: { settings.layout[selected].scale = CGFloat($0) }
        )
    }
}
