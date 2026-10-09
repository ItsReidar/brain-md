//
//  AIResultSheet.swift
//  brain-md
//

import AppKit
import SwiftUI

/// A Gemma request the editor wants reviewed before it touches the note.
struct AIResultRequest: Identifiable {
    let id = UUID()
    let title: String
    let stream: () -> AsyncThrowingStream<String, Error>
}

/// Streams Gemma's answer and lets the user insert it, replace the note with it, or discard it.
struct AIResultSheet: View {
    let request: AIResultRequest
    let onInsert: (String) -> Void
    let onReplace: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var phase: Phase = .loading
    @State private var generation: Task<Void, Never>?
    @State private var confirmingReplace = false

    private enum Phase: Equatable {
        case loading, streaming, finished, stopped
        case failed(String)
    }

    private var result: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBusy: Bool { phase == .loading || phase == .streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 480)
        .onAppear(perform: start)
        .onDisappear { generation?.cancel() }
        .confirmationDialog("Replace the whole note with this result?", isPresented: $confirmingReplace) {
            Button("Replace Note", role: .destructive) { finish(onReplace) }
        } message: {
            Text("The note's current text is overwritten. Insert Below keeps it instead.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(.purple)
            Text(request.title).font(.headline)
            Spacer()
            switch phase {
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading Gemma 4…").font(.caption).foregroundColor(.secondary)
            case .streaming:
                ProgressView().controlSize(.small)
                Text("Writing…").font(.caption).foregroundColor(.secondary)
            case .stopped:
                Text("Stopped").font(.caption).foregroundColor(.secondary)
            case .finished, .failed:
                EmptyView()
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            // Short answers sit at the top; while text streams in, the view follows the newest line.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }

    private var footer: some View {
        HStack {
            if isBusy {
                Button("Stop") { generation?.cancel(); phase = .stopped }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Discard", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
            .disabled(isBusy || result.isEmpty)
            Button("Replace Note…") { confirmingReplace = true }
                .disabled(isBusy || result.isEmpty)
            Button("Insert Below") { finish(onInsert) }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || result.isEmpty)
        }
        .padding(16)
    }

    private func start() {
        guard generation == nil else { return }
        generation = Task {
            do {
                for try await chunk in request.stream() {
                    phase = .streaming
                    text += chunk
                }
                if !Task.isCancelled { phase = .finished }
            } catch is CancellationError {
                phase = .stopped
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(_ action: (String) -> Void) {
        action(result)
        dismiss()
    }
}
