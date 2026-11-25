# Capture Machine

Record a window, a region, or your whole screen from the Mac menu bar. Capture Machine copies the finished MP4 or GIF as a file you can paste into Finder or a conversation. Everything is recorded and encoded on your Mac.

## Install

Download **Capture-Machine-1.0.0-arm64.dmg**, open it, and drag Capture Machine to Applications. Version 1.0.0 requires an Apple Silicon Mac and macOS 15 or later. [Releases](https://github.com/artisticmedic/capture-machine/releases)

To install the same disk image with Homebrew:

```sh
brew install --cask artisticmedic/tap/capture-machine
```

Open Capture Machine and click **Allow Screen Recording**. A panel attached to System Settings holds the app icon: drag it into the list, enter your Mac password, and choose **Quit & Reopen**. The optional **Show keys** setting asks for Input Monitoring the same way. Keys you display become visible in the recording. The app records video without audio.

## Record and share

1. Click the menu bar icon and pick a window, region, or the full screen. Click again to stop.
2. Paste the clip wherever you want to share it. A normal-speed MP4 is ready as soon as capture finishes. A GIF or a speed change is copied when encoding finishes. Copying something else during an export preserves that newer clipboard item.
3. For an MP4 larger than 10 MB, choose **Copy smaller MP4** in Preview. This targets 10 MB and shows the resulting size. The editor also supports custom size targets, trimming, frame-rate adjustments, half size and Save As. A target is best effort.

In Settings, choose the toolbar, default format and speed, keyboard shortcuts, and whether Stop opens Preview or the editor. You can also send the clip straight to the clipboard.

See the keyboard controls, size options and configuration keys in the [settings and editing guide](docs/guide.md).

## Where clips go

With **Save Recordings** on, Capture Machine keeps the working recording. Choose a folder for your finished clips, or leave it blank to use the app’s Recordings folder inside Application Support.

With saving off, closing the last Preview or editor window discards the working recording and its edits. With Clipboard only, the working files are discarded after delivery. **Edit Last Recording** cannot reopen a discarded recording.

Each copied clip has a separate file in Application Support/Capture Machine/Clipboard so it can still paste after closing Preview or quitting Capture Machine. Capture Machine removes a copy 7 days after it last copied it, at launch or at the next copy, but never the one the clipboard holds. **Keep copies for** in Settings changes that to 24 hours or 30 days. If another app has placed a file URL on the clipboard, cleanup may wait until the next Capture Machine copy. Clipboard managers control which formats they retain in their own histories.

## Build from source

Use Swift 6, Xcode with an actool that supports Icon Composer documents, and Rust with Cargo. From the project root run:

```sh
scripts/build-app.sh
swift test
open ".build/Capture Machine Dev.app"
```

The development app has its own bundle identifier and settings directory. The production bundle identifier is `com.timgailey.CaptureMachine`. Settings and CLI status live in `~/Library/Application Support/Capture Machine/` in the release app.

The command-line executable lives at `/Applications/Capture Machine.app/Contents/MacOS/CaptureMachine`. It supports these commands:

```text
CaptureMachine get [setting]
CaptureMachine status
CaptureMachine record --seconds 3 [--section x,y,width,height]
CaptureMachine export <file> [--speed 0.25|0.5|1|2] [--format mp4|gif] [--fps 30|20|15|10] [--half] [--target MB] [--estimate]
```

Capture Machine is distributed under the MIT license. Its separate GIF encoder, gifski 1.34.0, is licensed under AGPL-3.0-or-later. The release assets include the encoder’s corresponding source, dependencies and offline build instructions. [License](LICENSE) · [Attributions](NOTICE) · [Encoder notices](Resources/gifski/NOTICE)
