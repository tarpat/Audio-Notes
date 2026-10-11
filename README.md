# Audio Notes

A small macOS app for local lecture recording, Whisper transcription, and Ollama notes.

The Lectures screen also has a **Discord call** recording mode. It captures Mac output audio and the microphone, combines them into the usual `recording.m4a` when stopped, and then uses the same playback, transcription, and notes workflow. macOS requires Screen Recording and Microphone permissions for this mode; FFmpeg is used to combine the two sources. System audio capture includes output from other apps while recording.

## Build and run

Requires macOS 14 or newer and Swift 6. Build with:

```sh
./scripts/build-app.sh
```

This builds the release binary, creates the app icon, and assembles `.build/Audio Notes.app`. To install it as a regular app, drag `Audio Notes.app` from `.build` into `/Applications` in Finder. You can then launch it from Launchpad or Spotlight. Rebuild after changing the source, and replace the copy in Applications with the rebuilt bundle. The generated app is unsigned; macOS may ask you to confirm opening it the first time.

To build without opening the app, run `swift build -c release`. To create the icon separately, run `swift scripts/create-icon.swift Resources/AppIcon.icns`.

## GitHub Releases

Create and publish a release on GitHub (for example, with tag `v0.2.0`). The workflow in `.github/workflows/release.yml` builds a universal macOS app for Apple Silicon and Intel, then attaches `Audio-Notes-macOS.zip` to that release. The app is unsigned, so macOS may ask users to approve it when they first open it.

## Transcription setup

Install `whisper.cpp` and `ffmpeg` so `whisper-cli` and `ffmpeg` are available on your Mac. Select a compatible Whisper GGML model in Settings. The app converts M4A audio to a temporary WAV locally before transcription; audio is not uploaded.

## Notes setup

Start Ollama locally and have `qwen3.5:4b` installed. Notes are generated through `http://127.0.0.1:11434` and saved next to the transcript. Select 4B or 9B for a generation run.

## Files

By default, recordings are saved under `~/Documents/LectureRecorder`, grouped under a course folder. Each recording folder contains `recording.m4a`, `transcript.md`, and `notes.md`. Quick recordings get a start-time name such as `10-09-2026 11:21am`; edit the title before recording to use a custom name. Use Delete on a recording to remove its full folder and files.

Audio plays inside Audio Notes with an in-app seek slider. Generated notes are displayed as formatted Markdown in the app, while `notes.md` remains a portable Markdown file on disk. Note generation shows a progress bar and reports the current section when a long transcript is processed.
