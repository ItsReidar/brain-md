//
//  MeetingLiveOverlay.swift
//  brain-md
//

import SwiftUI

/// Floating panel shown while a meeting is recorded: per-source levels and the sentence in progress.
struct MeetingLiveOverlay: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var capture: AudioCaptureService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Recording").font(.system(size: 12, weight: .semibold))
                if capture.configuration.captureSystemAudio {
                    LevelMeter(label: "Them", level: capture.systemLevel)
                }
                if capture.configuration.captureMicrophone {
                    LevelMeter(label: "Me", level: capture.microphoneLevel)
                }
                if let status = recorder.status {
                    Text(status).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            ForEach([TranscriptionSegment.Speaker.systemAudio, .microphone], id: \.self) { speaker in
                if let text = recorder.liveText[speaker] {
                    Text("\(speaker == .microphone ? "Me" : "Them"): \(text)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording meeting")
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.green).frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(width: 44, height: 5)
            .animation(.linear(duration: 0.1), value: level)
        }
    }
}
