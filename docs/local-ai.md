# On-Device AI & Meetings

brain-md runs Google's **Gemma 4 E4B** on your Mac with [MLX](https://github.com/ml-explore/mlx-swift) for summaries, action items, rewriting, screen explanations and free-form chat, and uses Apple's on-device **SpeechAnalyzer** to transcribe meetings. Notes, audio and screenshots never leave the Mac; the only network traffic is the one-time model download from Hugging Face (and Apple's speech model download per language).

```mermaid
flowchart LR
  subgraph Capture
    SYS["System audio (Them)"]
    MIC["Microphone (Me)"]
    SCR["Screenshot (display under the pointer, or a picked window, app or display)"]
  end
  SYS -->|ScreenCaptureKit| SA1["SpeechAnalyzer"]
  MIC -->|ScreenCaptureKit| SA2["SpeechAnalyzer"]
  SA1 --> T["Transcript lines in the note"]
  SA2 --> T
  T --> G["Gemma 4 E4B (MLX)"]
  NOTE["Current note"] --> G
  SCR --> G
  G --> R["Review sheet: Insert below · Replace note · Copy · Discard"]
```

## Features

| Feature | Where | What happens |
|---|---|---|
| Skills | ✨ menu, and the chat's suggestions and **Skills** menu | Your saved prompts, as Markdown files in the vault (see [Instructions & Skills](#instructions--skills)). The defaults: Summarize Note, Extract Action Items, Polish & Rewrite, List the Open Questions and Suggest a Better Title |
| Explain Screen | ✨ menu › Explain Screen | **Screen Under Pointer** captures that display (without brain-md's windows). **Choose Window, App or Display…** opens the macOS picker so you can pick exactly what to explain. Gemma then explains the slide or diagram |
| Record a meeting | 🎙 toolbar button | Live transcript lines labelled **Them** / **Me** with timestamps; minutes from Gemma when you stop |
| Gemma Chat | ✨ menu › Chat with Gemma…, or View › Gemma Chat (⇧⌘J) | A conversation in its own window, optionally about the open note |

Gemma's output always opens in a **review sheet** first. Nothing is written to a note until you choose Insert Below or Replace Note (which asks for confirmation). Meeting transcript lines are the exception: they are written to the open note as they're finalized, and switching notes stops the recording.

Answers are in the note's language (in chat: the language you write in). Notes longer than about 8,000 tokens (32,000 characters) are truncated with a visible marker.

## Gemma Chat

A separate window for asking Gemma anything, without the preset actions.

- The **note chip** under the message field (on by default) sends the open note with your message; click it to leave the note out. It's sent once and again only after you edit it, so follow-up questions stay fast.
- An empty chat offers starting points: with a note, Summarize, Open questions, Action items and a better title (sent straight away); without one, prompts you complete yourself.
- Answers render Markdown (headings, lists, task boxes, quotes, tables and highlighted code blocks). Return sends; ⌥Return adds a line.
- Each answer has **Copy** and **Insert into Note**, which appends it to the note that's open at that moment.
- **Stop** (⌘.) ends an answer early; **New Chat** clears the conversation.
- The conversation lives in memory only: it isn't saved and is gone when you quit. When the model unloads after five idle minutes, the next message reloads it and replays the last 20 exchanges so Gemma still remembers the conversation.
- **Context usage** shows under the message field after the first answer, as a ring and "1.7K / 131K" tokens of Gemma's 131,072-token window. The ring turns amber at 70 % and red at 90 %; hover for exact numbers and the last answer's speed. A shared note counts too (roughly 1,000 tokens per 4,000 characters). Start a new chat when it's nearly full.
- Opening the window loads and warms up Gemma in the background, so the first answer starts in about a quarter of a second instead of about four.

## Instructions & Skills

**Settings › Local AI & Voice › Instructions & Skills**

- **Custom Instructions** (up to 2,000 characters) are added to every request, in chat and the ✨ menu, after the built-in rules: for example "Answer in Dutch. Keep it short." In chat, edits apply from the next message.
- **Skills** are saved prompts, stored as Markdown files in the vault's `Skills` folder, so they sync with your notes and you edit them like any note. Settings lists them with **Edit** (opens the file), **New Skill**, **Show in Finder** and **Restore Defaults** (re-adds missing default skills; edited ones are kept).

A skill file:

```markdown
---
name: Translate to Dutch
description: Translates the note
icon: globe                # an SF Symbol name
show-in: [menu, chat]      # the ✨ menu, the chat window, or both
uses-note: true            # adds the open note to the prompt
order: 10                  # lower comes first
---
Translate this note into Dutch, keeping its Markdown structure.
```

The body is the prompt. With `uses-note: true` the note is appended, or placed where `{{note}}` appears; with `false` the prompt is sent on its own. Missing fields default to the file name, `sparkles`, both places, `true` and 100. A file without a body is ignored.

In the ✨ menu a skill's answer opens in the review sheet. In chat it's sent as a message shown with the skill's name; a skill that uses the note always includes it, even when the note chip is off.

The five default skills are written the first time on-device AI is used with a vault. Deleting one is permanent; use **Restore Defaults** to get it back. The `Skills` folder sits under **App Folders** in the sidebar and is left out of the 3D graph (see [Vault Management](vault-management.md#app-folders)).

## Languages

Meetings are transcribed with Apple's **SpeechTranscriber**, the long-form model built for meetings, when it supports the language (English, French, German, Spanish and others). Languages it doesn't cover fall back to **DictationTranscriber**, which supports more, including **Dutch** (`nl_BE` and `nl_NL`). The Transcription Language picker lists every language either engine supports. A requested region the engines don't have maps to the language's main region (English in Belgium → `en_US`).

## Setup

**Settings › Local AI & Voice**

- **Enable on-device AI** downloads the model (6.8 GB) with live progress. Turning it off unloads the model and asks whether to delete the files.
- **Capture Incoming System Audio** / **Capture Microphone Audio** choose the meeting sources.
- **Instructions & Skills** set custom instructions and manage skills (see above).
- **Transcription Language** defaults to the system language. Each language's speech model downloads once, the first time it's used.
- **Visual Diagram Comprehension** shows or hides Explain Screen.

### Permissions

| Permission | Needed for | Asked |
|---|---|---|
| Screen & System Audio Recording | Explain Screen › Screen Under Pointer, system audio in meetings | On first use, by macOS |
| Microphone | Your side of a meeting | When recording starts |

Choosing content with the picker needs no Screen Recording permission: picking is the consent. If the permission is already granted, a picked display also leaves out brain-md's own windows.

Speech recognition permission is not requested: SpeechAnalyzer transcribes on-device without it. The usage string is declared as a safeguard.

## The model

- **Checkpoint:** [`mlx-community/gemma-4-E4B-it-qat-4bit`](https://huggingface.co/mlx-community/gemma-4-E4B-it-qat-4bit), the quantization-aware-trained 4-bit conversion, which keeps more quality than post-training 4-bit. Its feed-forward layers stay at 8-bit, hence 6.8 GB.
- **Not the "qat-mobile" checkpoint:** that export uses mixed 2/4-bit weights with activation scales that mlx-swift-lm can't load.
- **Pinned revision:** the download is pinned to commit `0f35c6f6`. swift-transformers still depends on yyjson 0.12.0 ([GHSA-f4vc-345x-4mvm](https://github.com/advisories/GHSA-f4vc-345x-4mvm)), which parses the model's JSON files, so only this known set of files is ever parsed. Unpin once [huggingface/swift-transformers#392](https://github.com/huggingface/swift-transformers/pull/392) ships (`TODO` in `LocalModelManager`).
- **Storage:** `~/Library/Application Support/brain-md/models`, in the Hugging Face cache layout.
- **Memory:** loading checks that about 1.2× the model size is free (roughly 8 GB) and fails with a clear message otherwise. The model loads on first use and unloads after five idle minutes.
- **Speed** (M2 Pro, measured with `GemmaBenchmarkTests`): about 31 tokens/s generated and 550–730 tokens/s of prompt read; loading takes about 4 s. Follow-up chat messages reuse the conversation's KV cache, so only the new message is read (about 0.2 s to the first word instead of re-reading the whole chat). mlx-swift-lm 3.32.3's Gemma 4 processor attaches an all-ones attention mask to every prompt, which disables that reuse; `TextMaskDroppingProcessor` in `HubAdapters.swift` drops it for text-only prompts. Larger prefill steps made no difference.
- **Audio:** Gemma 4's audio encoder isn't available in Swift (mlx-swift-lm drops `audio_tower` weights), so speech-to-text uses SpeechAnalyzer and Gemma works from the transcript.

## Code map

| File | Role |
|---|---|
| `Services/AI/LocalModelManager.swift` | Download, verify, load and unload the model |
| `Services/AI/HubAdapters.swift` | Bridges swift-huggingface and swift-transformers to mlx-swift-lm (replaces the MLXHuggingFace macros); drops Gemma 4's no-op attention mask so chat turns reuse the KV cache |
| `Services/AI/GemmaService.swift` | Prompts and streaming generation, prewarm, idle unload |
| `Services/AI/Skills.swift` | Skill file parsing, prompts, the vault's skill library and default skills |
| `Services/AI/GemmaChat.swift` | Chat state, note context, session rebuild from history, context usage |
| `Services/AI/VisualCaptureService.swift` | Full-resolution screenshot of the display under the pointer, or of a window, app or display chosen in the system picker |
| `Services/AI/AudioCaptureService.swift` | ScreenCaptureKit system audio + microphone, levels |
| `Services/AI/MeetingTranscriber.swift` | Engine and locale choice, one SpeechAnalyzer per source, format conversion, language assets |
| `Services/AI/MeetingRecorder.swift` | Recording session: capture → transcript lines → minutes |
| `Views/AIResultSheet.swift` | Review sheet |
| `Views/GemmaChatView.swift` | Gemma Chat window |
| `Views/MeetingLiveOverlay.swift` | Live levels and partial transcript while recording |

## Testing

Unit tests cover prompts, model-file verification, audio conversion and levels, transcript formatting and coordinate conversion. Tests that need the real model or speech engine are opt-in:

```bash
TEST_RUNNER_BRAINMD_MODEL_INTEGRATION=1 xcodebuild test -project brain-md.xcodeproj -scheme brain-md -destination 'platform=macOS' -only-testing:brain-mdTests
```

```bash
TEST_RUNNER_BRAINMD_SPEECH_INTEGRATION=1 xcodebuild test -project brain-md.xcodeproj -scheme brain-md -destination 'platform=macOS' -only-testing:brain-mdTests
```

The model tests need the model downloaded (enable on-device AI in the app first); they check that chat remembers the conversation after the model reloads and that a follow-up message reuses the KV cache. The speech tests synthesize sentences with `say` (Samantha in English; Ellen and Xander in Dutch, which need those voices installed) and check the transcripts, including a Dutch meeting with both sources at once. The first Dutch run downloads Apple's speech model.

Speed measurements are a separate opt-in suite. Turn parallel testing off so only one copy of the model runs; results are written as `BENCH` lines to the output file:

```bash
TEST_RUNNER_BRAINMD_MODEL_BENCHMARK=1 TEST_RUNNER_BRAINMD_BENCHMARK_OUT=/tmp/brainmd-bench.txt xcodebuild test -project brain-md.xcodeproj -scheme brain-md -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:brain-mdTests/GemmaBenchmarkTests
```

Not automated, because they need macOS permission prompts or system UI: a real screen capture, the content picker and a real call recording.
