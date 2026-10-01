//
//  CourseEditorView.swift
//  vr
//
//  The tray for building a course.
//

import SwiftUI

/// Sits along the bottom of the camera view while the course is being built.
///
/// Deliberately short: the room is what the player is building in, so the
/// tray takes a strip at the bottom and leaves the rest of the screen to the
/// camera. It shows the prop tools until something is selected, and the
/// selection's tools until it is let go.
struct CourseEditorView: View {

    @Bindable var model: ARExperienceModel
    @State private var isConfirmingClear = false

    private var course: CourseStatus { model.course }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            panel
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .confirmationDialog("Clear the course?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button(course.count == 1 ? "Remove 1 prop" : "Remove all \(course.count) props", role: .destructive) {
                model.clearCourse()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The car stays where it is. You can undo this.")
        }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            header

            Group {
                if let selected = course.selected {
                    selectionTools(for: selected)
                } else {
                    propTools
                }
            }
            .frame(height: 72)
            .animation(.easeInOut(duration: 0.18), value: course.selected)

            Text("Virtual props: the car hits these, not your real furniture.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        // Only the backing runs down behind the home indicator; the controls
        // stay above it, where a thumb can reach them without swiping home.
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                .fill(GaragePalette.midnight)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Course builder")
                    .font(GameType.display(22))
                Text("\(course.count) of \(CourseSpec.maxProps) props")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(course.isFull ? Color.orange : Color.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: course.count)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            HeaderIconButton(systemImage: "arrow.uturn.backward", label: "Undo",
                             isEnabled: course.canUndo, action: model.undoCourse)
            HeaderIconButton(systemImage: "trash", label: "Clear the course",
                             isEnabled: course.count > 0) { isConfirmingClear = true }

            Button(action: model.finishCourseEditing) {
                Label("Drive", systemImage: "steeringwheel")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GaragePalette.amberInk)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(
                        LinearGradient(colors: [GaragePalette.amberTop, GaragePalette.amberBottom],
                                       startPoint: .top, endPoint: .bottom),
                        in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Hides the editing aids and hands the controls back")
        }
    }

    // MARK: - Tools

    private var propTools: some View {
        HStack(spacing: 8) {
            ToolTile(title: "Cone", isSelected: course.tool == .cone, isEnabled: !course.isFull) {
                ConeIcon()
            } action: {
                model.selectCourseTool(.cone)
            }
            ToolTile(title: "Barrier", isSelected: course.tool == .barrier, isEnabled: !course.isFull) {
                BarrierIcon()
            } action: {
                model.selectCourseTool(.barrier)
            }
            ToolTile(title: "Tyre", isSelected: course.tool == .tyre, isEnabled: !course.isFull) {
                TyreIcon()
            } action: {
                model.selectCourseTool(.tyre)
            }
            ToolTile(title: "Slalom", isSelected: false, isEnabled: course.count <= CourseSpec.maxProps - SlalomPlanner.minimumCount) {
                SlalomIcon()
            } action: {
                model.addSlalom()
            }
            .accessibilityHint("Adds a row of cones in front of the car")
        }
    }

    private func selectionTools(for kind: PropKind) -> some View {
        HStack(spacing: 8) {
            SelectionButton(systemImage: "rotate.left", title: "Turn left", label: "Turn anticlockwise") {
                model.rotateSelectedProp(clockwise: false)
            }
            SelectionButton(systemImage: "rotate.right", title: "Turn right", label: "Turn clockwise") {
                model.rotateSelectedProp(clockwise: true)
            }
            SelectionButton(systemImage: "plus.square.on.square", title: "Copy",
                            label: kind == .barrier ? "Duplicate, end to end" : "Duplicate alongside",
                            isEnabled: !course.isFull, action: model.duplicateSelectedProp)
            SelectionButton(systemImage: "trash", title: "Delete", label: "Delete the \(kind.title.lowercased())",
                            role: .destructive, action: model.deleteSelectedProp)
            SelectionButton(systemImage: "checkmark", title: "Done", label: "Deselect", action: model.deselectProp)
        }
        .disabled(course.isAdjusting)
    }
}

/// One of the three big choices in the tray.
private struct ToolTile<Icon: View>: View {

    let title: String
    let isSelected: Bool
    var isEnabled: Bool = true
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon()
                    .frame(width: 44, height: 34)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? GaragePalette.indigo : GaragePalette.deepIndigo)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? GaragePalette.amberTop : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A labelled tool for the selected prop.
private struct SelectionButton: View {

    let systemImage: String
    let title: String
    let label: String
    var role: ButtonRole?
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// A small round button in the tray's header.
private struct HeaderIconButton: View {

    let systemImage: String
    let label: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
