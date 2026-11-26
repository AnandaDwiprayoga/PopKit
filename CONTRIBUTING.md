# Contributing to PopKit

Thanks for helping. Bug reports, fixes, extensions and docs are all welcome.

## Setting up

You need macOS 13+ and Swift 5.9+ (Xcode or the Command Line Tools).

```bash
git clone https://github.com/AnandaDwiprayoga/PopKit.git
cd PopKit
swift build
swift test                 # no network, no permissions needed
./build.sh --install       # build the app and run it from ~/Applications
```

macOS drops PopKit's Accessibility permission each time an ad-hoc-signed app changes, which gets tiring when you rebuild often. Create a self-signed code-signing certificate in Keychain Access and build with `POPKIT_SIGN_IDENTITY="Your Cert" ./build.sh --install` to keep it.

## How the code is laid out

```
Sources/PopKitCore/   Logic with no UI. Everything here is unit-tested.
Sources/PopKit/       The AppKit and SwiftUI app.
Tests/PopKitCoreTests/
Resources/Extensions/ Built-in extensions (Copy, Search), copied into the app by build.sh.
Examples/             Example extensions for the docs.
docs/extensions.md    The extension API reference.
```

**PopKitCore** (no UI, unit-testable):

| File | Job |
|---|---|
| `SelectionGesture`, `PopupPlacement` | Which gestures mean "a selection happened", and where the popup goes. Pure functions. |
| `ExclusionRules`, `PlacementRules`, `FieldRules` | Settings kept in UserDefaults: pause and excluded apps, popup side per app, what to assume about unknown fields. |
| `Manifest`, `OptionsStore` | `Config.json` parsing, and option values (UserDefaults, with secrets in the Keychain). |
| `ExtensionRuntime`, `JSShims` | One JavaScriptCore context per extension, with `require`, `axios`, `popclip` and friends. |
| `ExtensionStore`, `ExtensionManager` | Installed extensions on disk, and turning them into popup actions. |
| `HostAPI` | What an extension's `popclip` calls. The app implements it, tests use a fake. |

**PopKit** (the app):

| File | Job |
|---|---|
| `SelectionMonitor` | Global mouse and key events, debounced, into "a selection probably happened". It never reads text. |
| `SelectionReader` | Reads the selection and the field from the Accessibility API, with a ⌘C fallback. |
| `PopupController`, `PopupPanel` | The non-activating floating panel, the flow from gesture to popup, and the extension host. |
| `Paster`, `Keystroke` | Pasteboard save and restore, and synthetic ⌘C and ⌘V. |
| `SettingsView`, `ExtensionsTab`, `App` | Settings window, menu bar item, install flow. |
| `CLI`, `AXInspector`, `Diagnostics` | Headless commands and debugging tools. |

Layering rule: `PopKitCore` must not import AppKit or SwiftUI. If you are about to, the code probably belongs in `PopKit`, behind a small protocol in core.

## Tests

Put new logic in `PopKitCore` and test it there. The runtime tests use `FakeHost` (records what an extension asked for) and `StubURLProtocol` (fake network). Both are in `ExtensionTestSupport.swift`.

A few things worth knowing:

- Tests that touch UserDefaults use a throwaway suite, and the Keychain is replaced by `InMemorySecrets`. Don't let tests write to the real ones.
- `ShippedExtensionsTests` loads every extension in `Resources/Extensions` and `Examples`. Adding one there adds a test for free.
- **Optional compatibility tests.** If you have a PopClip-format extension you want to check, point `REFINE_EXT_DIR` at its folder to run `RefineEndToEndTests`, which are skipped otherwise. They are written against one specific extension, so treat them as an example of how to test a real one against a stubbed API.

## Debugging selection problems

Most bugs here are "PopKit doesn't see the selection in app X". Two tools help, and you don't need to attach a debugger:

1. **Debug Logging** in the PopKit menu writes one line per selection to `~/Library/Logs/PopKit.log`: the app, the focused field's role, whether it looked editable, whether an anchor was found, and which buttons were shown. It never includes the selected text. If the line says `no focused element`, the app isn't answering Accessibility queries, and the error codes after it say why (`-25211` API disabled, `-25204` cannot complete, `-25212` no value).
2. With Debug Logging on, `PopKit --probe <bundle id>` from a terminal asks the running app to dump the shape of that app's Accessibility tree into the log: roles and flags, no text. The terminal has no Accessibility permission, so the running app does the work.

Please include the relevant log lines in a bug report.

## Pull requests

- Keep a change to one thing, and say in the description what you tested by hand. Most of PopKit can only be checked in real apps, so name the apps.
- Add or update tests for logic in `PopKitCore`.
- If you change what extensions can do, update `docs/extensions.md` in the same PR.
- Don't add a dependency without discussing it first. PopKit has none today, and that is on purpose.
- Match the surrounding style. There is no formatter configured.

CI runs `swift build`, `swift test` and `./build.sh` on macOS.

## Writing and sharing extensions

Extensions are plain folders, so you can share one as a repository or a zip. See [docs/extensions.md](docs/extensions.md). If an extension needs something PopKit doesn't support yet, open an issue describing what it needs.

## Reporting security problems

PopKit reads text you select and runs extension code, so security reports matter. Please open a GitHub issue titled "Security" with no exploit details in it, and the maintainer will arrange a private channel.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
