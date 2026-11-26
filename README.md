# PopKit

A free, open-source selection popup for macOS. Select text in any app and a small action bar appears. Actions are installable JavaScript extensions, in a subset of the PopClip extension format.

**Status:** early. Selecting text shows a popup with a Copy button, and you can pause PopKit or exclude apps. The extension runtime isn't built yet.

For testing the paste path, run with `POPKIT_DEBUG_ACTIONS=1` to get a debug UPPERCASE button in editable fields.

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
