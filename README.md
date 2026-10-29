# ClipHistory

A clipboard history for macOS that works like Windows' **Win + V**. Press **⇧⌘V** anywhere, pick
something you copied earlier, and it's pasted into the app you're typing in.

## Features

- Remembers text, rich text, links, images and files (Finder copies). Formatting is kept when you paste.
- Opens under your text cursor when the app supports it, otherwise at the mouse pointer.
- Type to search. Hebrew, Arabic and other right-to-left text is shown right-aligned.
- Pin items so they stay at the top and survive **Clear all**.
- Skips passwords: content marked concealed by 1Password, Bitwarden, KeePassXC and similar apps isn't recorded.
- Lives in the menu bar (no Dock icon). From the menu you can pause recording, change the shortcut,
  set the history size (25 to 200 items) and turn on Open at Login.
- History is saved in `~/Library/Application Support/ClipHistory/`.

### Keys in the panel

| Key | Action |
| --- | --- |
| ↑ ↓ | Move the selection |
| ↩ | Paste |
| ⇧↩ or ⌥↩ | Paste as plain text |
| ⌘1 … ⌘9 | Paste item 1 to 9 |
| ⌘P | Pin or unpin |
| ⌘⌫ | Delete the item |
| Type | Search |
| Esc | Clear the search, then close |

Plain **⌘V** still pastes normally. ClipHistory sends ⌘V for you after you pick an item.

## Build

Requires macOS 13+ and Swift 5.9+. The Xcode Command Line Tools are enough.

```bash
make app       # builds build/ClipHistory.app
make run       # builds and launches it
make install   # copies it to /Applications and launches it
```

## Permissions

To paste into other apps, ClipHistory needs **Accessibility** access (System Settings → Privacy &
Security → Accessibility). Without it, choosing an item copies it and you press ⌘V yourself.

macOS ties this permission to the app's signature. Without a signing certificate the build is
ad-hoc signed, and every rebuild looks like a new app. The switch in System Settings stays on, but
it no longer applies, so ClipHistory keeps asking. Create a local signing certificate once and
every later build keeps the permission:

```bash
scripts/setup-signing.sh   # adds "ClipHistory Local Signing" to your login keychain
make install               # macOS may ask for your login password once: choose Always Allow
```

Then, one last time, open Accessibility settings, select ClipHistory, click − to remove it, and
click + to add `/Applications/ClipHistory.app` again.

To use a different identity: `SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" make app`.
