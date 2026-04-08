# GUI App

This directory contains a separate native AppKit wrapper for `smb2fs`.

## Layout

- `main.m`, `SMBAppDelegate.h`, `SMBAppDelegate.m`: app entry point and UI logic
- `Info.plist`: app bundle metadata
- `Makefile`: Lion-friendly build
- `Assets/Icon.png`: source artwork for the app icon

## Goals

- Keep the CLI and GUI as two separate things
- Use the existing `smb2fs` binary as the real engine
- Stay compatible with macOS 10.7 Lion
- Keep the first GUI thin and easy to maintain

## Current shape

- Native Objective-C/AppKit app
- Programmatic UI, no nib or storyboard
- Single connection list as the main window
- Native programmatic menu bar with App, File, Actions, Connections, Window, and Help menus
- Modal connection editor instead of a permanent split form
- Share picker powered by `smb2fs --list-shares`, available both from the main Actions menu and directly inside the connection editor
- Mount and unmount actions on the selected connection
- JSON import/export for one connection or the full saved list

## Build

Build the whole project from the repository root:

```bash
make
```

Or, if you only want to rebuild the GUI from this directory:

```bash
cd gui
make
```

The app bundle is written to:

```text
gui/build/SMB2FUSE.app
```

If `../cli/smb2fs` exists, the build copies it into the app bundle as `Contents/Resources/smb2fs`.
If `Assets/Icon.png` exists, the build also converts it into a proper `.icns` app icon and copies it into the bundle.

## Notes

- The GUI launches `smb2fs` with `NSTask`; it does not reimplement SMB logic.
- Finder is still the file browser. The GUI is only for connection management.
- Passwords are never saved in connections or export files.
- If you choose to remember a password, the GUI stores it in your Mac keychain.
- Connection export files use JSON and never include passwords or mount state.
- If a connection has a user, the app reuses any saved Keychain password first, otherwise it prompts and can optionally save it after a successful connection.
