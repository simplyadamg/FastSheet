# FinderStack

FinderStack is a lightweight native macOS menu-bar app that keeps a searchable stack of folders visited in Finder.

## Features

- Tracks the 100 most recently visited Finder folders.
- Opens from a configurable global hotkey.
- Provides a persistent, manually ordered folder Hotlist.
- Supports drag-and-drop Hotlist organization.
- Opens one folder in an arranged Finder window.
- Cmd-clicks up to four folders into upper-right, lower-right, upper-left, and lower-left layouts.
- Can launch automatically at login.

## Requirements

- macOS 15 Sequoia or newer.
- Permission to automate Finder when macOS prompts for it.

## Build

FinderStack uses Swift Package Manager and builds with the included script:

```sh
./build-app.sh
```

The standalone application is created at `FinderStack.app`.

## Usage

1. Build and open `FinderStack.app`.
2. Choose **Set Hotkey…** from the menu-bar icon and record a shortcut.
3. Use the shortcut to open or close FinderStack.
4. Click a recent folder to open it.
5. Add folders to the Hotlist with `+`, or drag them from Recent into Hotlist.
6. Hold Command and click up to four folders, then release Command to open the layout.

The Cmd-click assignment order is UR, LR, UL, then LL.

## Privacy

Folder history and Hotlist data are stored locally in macOS user defaults. FinderStack does not send folder information anywhere.

## License

FinderStack is available under the MIT License.
