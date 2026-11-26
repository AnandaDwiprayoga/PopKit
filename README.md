# PopKit

A free, open-source selection popup for macOS. Select text in any app and a small action bar appears. Actions are installable JavaScript extensions, in a subset of the PopClip extension format.

**Status:** early. Selecting text shows a popup. Its buttons come from extensions: Copy and Search are built in, and you can install more with **Install Extension…** in the menu bar menu. You can also pause PopKit, exclude apps, and choose per app whether the popup sits above or below the text.

Try the example: install `Examples/Uppercase.popkitext`, select text in an editable field, and click **AA**. Hold ⌥ to preview first.

## Headless

Run an extension without the popup, for scripts and debugging:

```bash
PopKit.app/Contents/MacOS/PopKit --list  <extension folder>
PopKit.app/Contents/MacOS/PopKit --run   <extension folder> "<action title or number>" "<text>" [--modifiers option] [--editable]
PopKit.app/Contents/MacOS/PopKit --install <extension folder>
```

Option values come from `POPKIT_OPT_<NAME>` environment variables (for example `POPKIT_OPT_APIKEY`), then the Keychain, then the extension's defaults. Exit code 2 means the extension asked for its settings.

## Build

Needs macOS 13+ and a Swift toolchain (Xcode or Command Line Tools).

```bash
./build.sh             # build/PopKit.app
./build.sh --install   # also copy to ~/Applications and open it
swift test
```

PopKit needs Accessibility permission to read your selection. macOS forgets that permission each time an ad-hoc-signed app is rebuilt, so set `POPKIT_SIGN_IDENTITY` to a stable self-signed code-signing certificate to keep it.

## License

MIT
