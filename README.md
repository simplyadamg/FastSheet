# FastSheet

FastSheet is a lightweight native macOS menu-bar spreadsheet and quick calculator for macOS.

## Features

- Opens from a configurable global hotkey. The default is `⌘⌃⌥⇧H`.
- Provides a compact floating spreadsheet popup.
- Persists workbook data and multiple sheet tabs locally.
- Supports keyboard navigation, rectangular selection, row/column selection, and range clearing.
- Supports copy, cut, and paste with formula reference translation.
- Supports undo and redo with `⌘Z` and `⌘⇧Z`.
- Supports arithmetic formulas, cell references, parentheses, and `SUM` ranges.
- Supports formula/pattern extension using the fill handle.
- Can launch automatically at login.

## Requirements

- macOS 15 Sequoia or newer.

## Build

FastSheet uses Swift Package Manager and builds with the included script:

```sh
./build-app.sh
```

The standalone application is created at `FastSheet.app`.

## Usage

1. Build and open `FastSheet.app`.
2. Use `⌘⌃⌥⇧H` to open or close the popup.
3. Click a cell to select it, double-click or press F2 to edit it.
4. Enter formulas such as `=A1+B1` or `=SUM(D:D)`.
5. Use the fill handle at the lower-right of a selection to extend formulas.
6. Use `⌘C`, `⌘X`, `⌘V`, `⌘Z`, and `⌘⇧Z` for clipboard and history operations.

The menu-bar icon provides hotkey configuration, Launch at Login, and Quit.

## Privacy

Workbook data and preferences are stored locally in macOS user defaults. FastSheet does not send spreadsheet data anywhere.

## License

FastSheet is available under the MIT License. Contributions are welcome.
