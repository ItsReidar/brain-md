//
//  ModelSettingsViews.swift
//  brain-md
//
//  Model lists for Settings › Local AI & Voice: download, delete and pick models from the catalog.
//

import SwiftUI

/// One catalog model: name, size, capabilities and licence, with its download state and actions.
struct ModelRow: View {
    let model: ModelDescriptor
    let isSelected: Bool
    /// False for the diarizer, which has no "Use" choice.
    var isSelectable = true
    let onUse: () -> Void
    let onDelete: (ModelDescriptor) -> Void
    @ObservedObject var store: ModelStore = .shared

    private var state: ModelDownloadState { store.state(of: model) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                .opacity(isSelectable ? 1 : 0)
                .accessibilityHidden(true)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.system(size: 13, weight: .medium))
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(model.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(ModelRow.format(model.approximateBytes)) · \(model.license) · \(model.repo)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if state.status == .downloading {
                    ProgressView(value: state.progress).progressViewStyle(.linear)
                    Text(state.totalBytes > 0
                        ? "\(ModelRow.format(state.bytesDownloaded)) of \(ModelRow.format(state.totalBytes))"
                        : "Contacting Hugging Face…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if state.status == .error {
                    Text(state.errorMessage ?? "The download failed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.displayName)\(isSelected ? ", selected" : "")")
    }

    private var badges: [String] {
        switch model.kind {
        case .language(let vision, let audio):
            (model.isInstructionTuned ? [] : ["Base"]) + (vision ? ["Images"] : []) + (audio ? ["Speech"] : [])
        case .speech(_, let streaming): streaming ? ["Live"] : []
        case .diarizer(let maxSpeakers): ["Up to \(maxSpeakers)"]
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state.status {
        case .notDownloaded:
            Button("Download") { store.startDownload(model) }
                .disabled(!ModelStore.isSupportedHardware)
        case .downloading:
            Button("Cancel") { store.cancelDownload(model) }
        case .error:
            Button("Retry") {
                store.refresh(model) // clears the error, keeps already-downloaded files
                store.startDownload(model)
            }
        case .ready:
            HStack(spacing: 6) {
                if isSelectable, !isSelected {
                    Button("Use", action: onUse).buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) { onDelete(model) } label: { Image(systemName: "trash") }
                    .help("Delete \(model.displayName)")
                    .accessibilityLabel("Delete \(model.displayName)")
            }
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// "Apple Speech (built in)": the no-download speech option.
struct AppleSpeechRow: View {
    let isSelected: Bool
    let onUse: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("No speech model").font(.system(size: 13, weight: .medium))
                Text("Uses Gemma 4 E4B when it's the active language model, otherwise Apple Speech (built into macOS).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isSelected { Button("Use", action: onUse) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No speech model\(isSelected ? ", selected" : "")")
    }
}
