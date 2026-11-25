# Settings and editing

## Settings and status

`~/Library/Application Support/Capture Machine/` holds `config.json` and `status.json` (`Capture Machine Dev/` for the development build and for binaries run from `.build`). The settings window (right-click the icon, or Settings… in the drop-down) edits it. `config.json` is written with defaults on first run and re-read at each recording, so edits apply without a relaunch. A file with an error keeps the settings that can still be read, is never overwritten, and its problem shows in `status.json` as `configNotice`.

| Key | Default | Values |
| --- | --- | --- |
| `toolbar` | `"dropDown"` | `"dropDown"` (a panel under the icon), `"bottomBar"` (a bar at the bottom of the screen, like ⌘⇧5), `"none"` (straight to the area picker) |
| `format` | `"mp4"` | `"mp4"`, `"gif"`: only the selected format is copied, after its export finishes |
| `afterCapture` | `"preview"` | `"clipboard"` (nothing opens), `"preview"` (the preview window), `"editor"` (the editor) |
| `speed` | `1` | `0.25`, `0.5`, `1`, `2`: the speed each clip starts at. The preview window can change it per clip |
| `save` | `true` | Put each clip in `saveFolder`. Off keeps nothing but the clipboard copy (below) |
| `saveFolder` | `""` | A folder path, `~` allowed. Empty keeps clips in the app's `Recordings` folder |
| `keepCopiesDays` | `7` | `1`, `7` or `30`. With `save` off, days a clipboard copy stays after the app last copied it |
| `keyCast` | `"off"` | `"off"`, `"shortcuts"` (shortcuts and keys like Return and the arrows), `"all"` (everything typed): the keys pressed while recording, drawn into the recording as a chip near the bottom of the recorded area. Needs Input Monitoring |
| `shortcuts` | all `""` | Global shortcuts for `toggle` (what a click on the icon does), `section`, `window`, `fullScreen` and `lastSection`, written like `"ctrl+opt+cmd+s"` or `"shift+cmd+f5"`. A shortcut needs ⌘, ⌃ or ⌥ unless it's a function key. None are set at first; each also stops a recording. Edits apply at once |

## Key-cast

With Show keys on, the keys pressed while recording show as a chip near the bottom of the recorded area, and the chip is in the recording: SF Mono semibold on near-black, with a white ring, as KeyCats draws its labels, so it reads over light and dark apps. Typed characters run together into one chip until a pause; a shortcut gets its own. The keys come from a listen-only event tap, which never holds up or changes a key and needs Input Monitoring rather than Accessibility; it runs only while recording. Password fields turn on secure input, which keeps their keys from every tap. The code is ported from George Karagkiaouris's MIT key-cast (credited in NOTICE).

## The area picker

Drag for a section, point at a window, or take the whole screen. A dragged section snaps to window edges, the screen's edges, the menu bar and the Dock within 8 points; hold ⌘ to place it freely. The size readout shows the pixels and frame rate the recording will have.

The last section on each screen is remembered, across launches. The bottom bar starts with it selected; the drop-down and No toolbar outline it, and Return records it (with No toolbar, F records the full screen). The arrow keys move it a point at a time, 10 with Shift; with ⌥ they move its right and top edges instead.

## The preview window and the editor

Both show every choice in the clip at once: the speed as the play rate, the trim as the loop, and a GIF's frame rate and Half size on the picture. The default format and speed start rendering at Stop. Choose Copy to render a subsequent edit. No control locks while a clip is made; changing a choice stops it, and the clipboard and save folder keep the earlier clip.

The preview window floats in the bottom-right corner of the screen with the trim bar, MP4 or GIF, the speed and, for a GIF, Smaller. Show in Finder, Open in Editor and Close sit on the clip's corners while the pointer is over the window. It closes on its own a few seconds after the pointer leaves, unless choices aren't copied yet.

For an MP4 over 10 MB, **Copy smaller MP4** sits under Copy. It uses Target size at 10 MB, keeps the full-size copy on the clipboard until the smaller one is ready, and then reads **Copy full size** to switch back. A 32.8 MB, 16-second full-screen recording became 9.6 MB.

Copy puts the clip back on the clipboard after something else was copied. A clip made while something else was copied, such as a GIF finishing after a copy of text, leaves the clipboard alone; it still goes to the save folder.

The editor (After recording: Editor, the preview's Open in Editor, or Edit Last Recording… in the icon's menu) adds a timeline of frames with trim handles and a playhead, all three Smaller levers for MP4 and GIF, the size estimate, and Save As. Keys: Space plays and pauses, ← and → step a frame, I and O trim to the playhead, Return copies, ⌘S saves as.

**Smaller.** Fewer frames (30, 20, 15 or 10 fps) and Half size apply to both formats. Target size (1, 2, 5, 10 or 25 MB, or any number) lowers the frame rate, then the size, then a GIF's quality until the clip fits, and makes it again a step lower when the made file is still over. An MP4 that already fits is kept as it is; otherwise its bit rate is set to fit, stepping the frame rate and size down first when that would leave too few bits for each pixel.

**Size estimate.** An MP4's comes from the recording's own size. A GIF's makes the whole GIF at about 400 pixels wide, which keeps gifski's own handling of what changes from frame to frame, and scales it by how much more a run of eight frames costs at full size, the run where a scan of the clip finds the most change. On a 6.5-second, 2530 × 1752 recording it came within 22% of the made GIF in four settings, in about two seconds.
