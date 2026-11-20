import SwiftUI

/// Settings › Sites › Pinned sites: reorder and unpin pinned sites, pin or remove
/// other visited sites, and add any site by address.
struct SettingsForumsPage: View {
    @ObservedObject var app: AppModel
    @State private var removing: Forum?
    @State private var address = ""
    @State private var pinNew = true
    @State private var adding = false
    @State private var addError: String?
    @State private var addedName: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        List {
            Section {
                if app.pinnedForums.isEmpty {
                    Text("Pin sites to keep them on Home.", comment: "Settings › Sites › Pinned sites empty state")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.pinnedForums) { forum in
                        forumRow(forum)
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) { removing = forum }
                                Button("Unpin") { withAnimation { app.unpin(forum) } }
                                    .tint(.orange)
                            }
                    }
                    .onMove { source, destination in
                        app.movePinned(fromOffsets: source, toOffset: destination)
                    }
                }
            } header: {
                HStack {
                    Text("Pinned")
                    Spacer()
                    if app.pinnedForums.count > 1 {
                        EditButton()
                            .font(.footnote.weight(.semibold))
                            .textCase(nil)
                    }
                }
            } footer: {
                if !app.pinnedForums.isEmpty {
                    Text("Pinned sites appear on Home in this order.", comment: "Settings › Sites › Pinned sites footer")
                }
            }

            if !app.recentForums.isEmpty {
                Section {
                    ForEach(app.recentForums) { forum in
                        forumRow(forum)
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) { removing = forum }
                                Button("Pin") { withAnimation { app.pin(forum) } }
                                    .tint(DCTheme.goldInk)
                            }
                    }
                } header: {
                    Text("Other sites you visited", comment: "Settings › Sites › Pinned sites section header for unpinned sites")
                } footer: {
                    Text("Swipe left to remove a site. You can keep or delete its saved data.", comment: "Settings › Sites › Pinned sites section footer for unpinned sites")
                }
            }

            addSection
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            removing.map { String(localized: "Remove \($0.displayName)?", comment: "Confirmation title; the argument is a site name") } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { forum in
            Button("Remove and delete saved data", role: .destructive) {
                withAnimation { app.removeForum(forum, deleteData: true) }
            }
            Button("Remove, keep saved data") {
                withAnimation { app.removeForum(forum, deleteData: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { forum in
            let count = app.savedItemCount(forSiteURL: forum.siteURL)
            if count > 0 {
                Text("Also delete saved data for this site? It has \(count) saved items.",
                     comment: "Remove site confirmation; the count is the site's saved summaries and conversations")
            } else {
                Text("Also delete saved data for this site?", comment: "Remove site confirmation when no saved items exist")
            }
        }
    }

    private func forumRow(_ forum: Forum) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            OnboardingForumIcon(siteURL: forum.siteURL, name: forum.displayName, iconURL: forum.iconURL, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(forum.displayName).lineLimit(2)
                Text(forum.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: DCTheme.spacingS)
            if !forum.isPinned {
                Button {
                    withAnimation(DCMotion.quick) { app.togglePin(forum) }
                } label: {
                    PinPill()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pin \(forum.displayName)")
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: forum.isPinned)
        .contextMenu {
            Button {
                app.togglePin(forum)
            } label: {
                Label(forum.isPinned ? "Unpin" : "Pin", systemImage: forum.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                // Present after the context menu has dismissed, or the
                // dialog is dropped on iPad.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    removing = forum
                }
            } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
        // A container, so the pin button keeps its own label/identity.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsForum-\(forum.host)")
    }

    private var addSection: some View {
        Section {
            HStack(spacing: DCTheme.spacingS) {
                TextField("example.com" as String, text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(add)
                    .accessibilityIdentifier("settingsForumAddress")
                if adding {
                    ProgressView()
                } else {
                    Button("Add", action: add)
                        .fontWeight(.semibold)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("settingsAddForum")
                }
            }
            Toggle("Pin it", isOn: $pinNew)
                .sensoryFeedback(.success, trigger: addedName) { _, new in new != nil }
                .sensoryFeedback(.warning, trigger: addError) { _, new in new != nil }
            if let addError {
                Label(addError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(DCTheme.danger)
            } else if let addedName {
                Label("Added \(addedName).", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(DCTheme.success)
            }
        } header: {
            Text("Add a site", comment: "Settings › Sites › Pinned sites section header for adding any site")
        } footer: {
            Text("Enter any web address or paste a link to a page.", comment: "Settings › Sites › Pinned sites footer for adding any site")
        }
    }

    private func add() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !adding else { return }
        adding = true
        addError = nil
        addedName = nil
        Task {
            do {
                let forum = try await app.addForum(fromAddress: trimmed, pin: pinNew)
                withAnimation { addedName = forum.displayName }
                address = ""
                addressFocused = false
            } catch {
                withAnimation { addError = error.localizedDescription }
            }
            adding = false
        }
    }
}

/// The "Pin" seal on forums that aren't pinned yet.
private struct PinPill: View {
    var body: some View {
        DCSeal(text: String(localized: "Pin"), variant: .gold)
            // 44 pt to tap; the seal stays compact.
            .frame(minWidth: DCTheme.controlHeight, minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
    }
}
