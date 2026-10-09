import SwiftUI

struct GitActionsMenuButton: View {
    let presentation: GitToolbarPresentation
    let isEnabled: Bool
    let fetchDisabled: Bool
    let writesDisabled: Bool
    /// Leaves only the branch and Changes in the menu, for a read-only repository
    /// (`GitWriteAvailability.hidesWrites`), whose branch the composer's picker doesn't show.
    var hidesWrites = false
    let isRunningAction: Bool
    let onTap: () -> Void
    let onChanges: () -> Void
    let onStageEdit: () -> Void
    let onCommit: () -> Void
    let onCommitAndPush: () -> Void
    let onFetch: () -> Void
    let onPull: () -> Void
    let onPush: () -> Void

    private var hasChanges: Bool {
        (presentation.status?.changedCount ?? 0) > 0
    }

    var body: some View {
        Menu {
            if hidesWrites, let branch = presentation.branchSummary {
                Section {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
            }

            Section("Changes") {
                Button(action: onChanges) {
                    changesLabel
                }
                .disabled(!presentation.changesAreEnabled)

                if !hidesWrites {
                    Button(action: onStageEdit) {
                        Label("Stage Changes…", systemImage: "checklist")
                    }
                    .disabled(!presentation.changesAreEnabled || !hasChanges)
                }
            }

            if !hidesWrites { writeSections }
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .frame(width: 24, height: 24)
        }
        .disabled(!isEnabled)
        .simultaneousGesture(TapGesture().onEnded(onTap))
        .frame(minWidth: 28, minHeight: 28)
        .accessibilityLabel("Git actions")
        .accessibilityValue(Text(presentation.accessibilityValue))
    }

    @ViewBuilder
    private var writeSections: some View {
        Section("Write") {
            HapticButton(feedbackStyle: .medium, action: onCommit) {
                Label("Commit", systemImage: "checkmark.seal")
            }
            .disabled(writesDisabled || isRunningAction || !hasChanges)

            HapticButton(feedbackStyle: .medium, action: onCommitAndPush) {
                Label("Commit & Push", systemImage: "arrow.up.doc")
            }
            .disabled(writesDisabled || isRunningAction || !hasChanges)

            HapticButton(feedbackStyle: .medium, action: onPush) {
                Label("Push", systemImage: "arrow.up.circle")
            }
            .disabled(writesDisabled || isRunningAction)
        }

        Section("Update") {
            HapticButton(feedbackStyle: .medium, action: onFetch) {
                Label("Fetch", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .disabled(fetchDisabled || isRunningAction)

            HapticButton(feedbackStyle: .medium, action: onPull) {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            .disabled(writesDisabled || isRunningAction)
        }
    }

    @ViewBuilder
    private var changesLabel: some View {
        if presentation.statusFailed {
            Label("Changes unavailable", systemImage: "exclamationmark.circle")
        } else if let status = presentation.status, status.changedCount > 0 {
            Label {
                Text("+\(status.totalAdditions)").foregroundStyle(.green)
                + Text("  −\(status.totalDeletions)").foregroundStyle(.red)
                + Text("  \(status.changedCount)").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "doc.text.magnifyingglass")
            }
        } else {
            Label("No changes", systemImage: "checkmark.circle")
        }
    }
}
