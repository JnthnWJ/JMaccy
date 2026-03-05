
<img width="128px" src="https://maccy.app/img/maccy/Logo.png" alt="Logo" />

# JMaccy

JMaccy is a fork of Maccy with a stronger "daily-driver" workflow: a vertical Shelf layout, iCloud history sync, and tagging for organization.

JMaccy works on macOS 14+.

## Features

### Vertical Shelf Mode (Main Feature)

JMaccy adds a Shelf layout that presents clipboard history as a more structured, vertical workflow inspired by the paid Past app experience.

* Enable it in `Preferences -> Appearance -> Layout -> Shelf`
* Optimized for scanning, previewing, and organizing larger histories
* Includes richer card-like metadata and a focused item preview workflow

Note: Shelf layout currently requires macOS 26+.

### iCloud Clipboard Sync

Clipboard history can sync across your devices through iCloud.

* Enable it in `Preferences -> Storage -> Sync & Encryption`
* Optional encryption for local + iCloud synced history
* Sync scope options: all items, pinned items only, or text only
* Tags are synced across devices as well

### Tagging

JMaccy adds tag-based organization for clipboard history.

* Create tags from the Shelf header
* Assign tags to items from item actions
* Filter history by tag
* Rename/delete tags and customize their colors

### Core Maccy Behavior

* Lightweight and keyboard-first clipboard history
* Fast search and quick paste/copy actions
* Pinning, deleting, clearing, and ignore controls
* Native macOS UI

## Install

### Option 1: Download a release

Download the latest app build from the [JMaccy releases](https://github.com/JnthnWJ/JMaccy/releases/latest) page.

### Option 2: Build from source

```sh
git clone https://github.com/JnthnWJ/JMaccy.git
cd JMaccy
open Maccy.xcodeproj
```

Build and run the `Maccy` target in Xcode.

## Usage

1. Press <kbd>SHIFT (⇧)</kbd> + <kbd>COMMAND (⌘)</kbd> + <kbd>C</kbd> to open JMaccy.
2. Type to search clipboard history.
3. Press <kbd>ENTER</kbd> to copy selected item, or <kbd>OPTION (⌥)</kbd> + <kbd>ENTER</kbd> to paste it.
4. Use <kbd>OPTION (⌥)</kbd> + <kbd>P</kbd> to pin/unpin.
5. In Shelf mode, use tags to group and filter items.

## Advanced

### Ignore Copied Items

```sh
defaults write com.jnthnwj.JMaccy ignoreEvents true
```

Set it back to `false` to resume capture.

### Ignore Custom Copy Types

Open `Preferences -> Ignore -> Pasteboard Types` to add custom types you want to skip.

Useful helper app: [Pasteboard-Viewer](https://github.com/sindresorhus/Pasteboard-Viewer).

### Speed up Clipboard Check Interval

```sh
defaults write com.jnthnwj.JMaccy clipboardCheckInterval 0.1
```

## FAQ

### Why doesn't it paste when I select an item in history?

1. Enable "Paste automatically" in Preferences.
2. Make sure JMaccy has Accessibility permission in macOS settings.

### How do I restore a hidden footer?

Run:

```sh
defaults write com.jnthnwj.JMaccy showFooter 1
```

### How do I ignore Universal Clipboard copies?

Add `com.apple.is-remote-clipboard` in `Preferences -> Ignore -> Pasteboard Types`.

### My keyboard shortcut stopped working in password fields. How do I fix this?

Use [Karabiner-Elements](https://karabiner-elements.pqrs.org/) to remap to a non-text-producing shortcut (example: `Cmd+Shift+C`). More detail: [docs/keyboard-shortcut-password-fields.md](docs/keyboard-shortcut-password-fields.md).

## License

[MIT](./LICENSE)
