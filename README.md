# PopKit

A free, open-source selection popup for macOS. Select text in any app and a small bar of buttons appears next to it. Each button is a JavaScript extension, so you can add your own: rewrite with an AI model, translate, search, count words, anything you can write in a few lines.

PopKit runs extensions written in a subset of the PopClip extension format, so extensions that stick to that subset work in both. See [docs/extensions.md](docs/extensions.md). PopKit is an independent project and is not affiliated with or endorsed by PopClip or Pilotmoon.

> **Status: early (0.1).** It runs on the author's Mac, but it has not been tested on many setups. Expect rough edges, and please open an issue when you find one.

## Features

- **Appears when you select.** After a drag, a double or triple click, or Shift+arrow / ⌘A. It never appears in password fields, and hides when you click elsewhere, type, scroll, press Esc or switch apps.
- **Extensions.** Copy and Search are built in. Install more from a folder, with a confirmation that shows what the extension can do.
- **Replace or preview.** Extensions can replace the selection in an editable field, show a result you click to paste, or open a large card for long text. Your clipboard is restored after a paste.
- **Pause and exclude.** Pause PopKit from the menu bar, and exclude apps. Password managers are excluded by default.
- **Position per app.** Show the popup above or below the text, with an override per app. For example, below the text in Slack so it doesn't cover Slack's formatting bar.
- **Options and secrets.** Extensions declare settings, and PopKit builds the form. Secrets such as API keys go in the Keychain.
- **Scriptable.** Run any extension from a terminal to test it. See [docs/extensions.md](docs/extensions.md#testing-from-the-command-line).

## Install

There is no signed release yet. Build it from source, which takes a minute.

You need macOS 13 or later and a Swift toolchain (Xcode or the Command Line Tools).

```bash
git clone https://github.com/AnandaDwiprayoga/PopKit.git
cd PopKit
./build.sh --install     # builds, copies to ~/Applications/PopKit.app and opens it
```

`./build.sh` alone builds `build/PopKit.app` without installing.

### Permissions

PopKit asks for **Accessibility** access in System Settings → Privacy & Security → Accessibility. It needs it to see which text you selected and to copy or paste it for you. It starts working as soon as you turn it on. macOS may also ask for Input Monitoring so PopKit can notice a Shift+arrow selection. Nothing works without these permissions, and PopKit can't be sandboxed because of them.

**Keep the permission across rebuilds.** macOS forgets an Accessibility grant whenever an ad-hoc-signed app changes. If you rebuild often, create a self-signed code-signing certificate in Keychain Access (Certificate Assistant → Create a Certificate → Code Signing) and build with it:

```bash
POPKIT_SIGN_IDENTITY="My PopKit Cert" ./build.sh --install
```

## Use it

Select some text. Click a button. That's it.

The PopKit icon in the menu bar has:

- **Pause PopKit**, and **Exclude <app>** for the app you were just using.
- **Show Popup Below Text in <app>**, to move that app to the other side.
- **Install Extension…** and **Settings…**.

Settings has four tabs: General (pause, default side, launch at login, permission status), Extensions (turn on or off, reorder, options, log, remove), Position (per-app side) and Excluded Apps.

## Extensions

Try an example: **Install Extension…**, choose `Examples/Uppercase.popkitext`, select text in an editable field and click **AA**. Hold ⌥ to preview the result first.

| Example | Shows |
|---|---|
| [`Uppercase`](Examples/Uppercase.popkitext) | Replacing the selection, ⌥ for a preview |
| [`WordCount`](Examples/WordCount.popkitext) | A plain notice, working on read-only text |
| [`Define`](Examples/Define.popkitext) | The network entitlement, `axios`, the large text card |

Writing your own is a `Config.json` and a JavaScript file. The full reference is in [docs/extensions.md](docs/extensions.md).

### Featured extension: Refine ✨

[**Refine**](https://github.com/AnandaDwiprayoga/Refine-Popclip) turns rough drafts into natural English right where you type. Select text in Slack, Mail, a browser text box or any editable field and click a button. The selection is replaced with a clean rewrite in your own voice. It is made for non-native speakers who write in a mix of languages: Bahasa Indonesia, chat slang and broken English all come out as friendly-professional English.

- Four rewrite styles: **My style**, **Polite**, **Short** and **Fix only**. Hold ⌥ to preview before pasting.
- A 🇮🇩 button that translates any selected text into Bahasa Indonesia, including text you can't edit.
- A privacy guard: links, emails, keys, phone numbers, code and words you list are swapped for placeholders before anything leaves your Mac, and put back afterwards.
- Uses [Groq](https://groq.com)'s free tier, so you need a free API key.

It was written for PopClip and runs unchanged in PopKit. To install it:

```bash
git clone https://github.com/AnandaDwiprayoga/Refine-Popclip.git
```

Then choose **Install Extension…** in the PopKit menu and pick the `Refine.popclipext` folder inside the clone. Open **Settings → Extensions → Refine** and paste your Groq API key, which PopKit keeps in your Keychain. The Refine repository has the details on styles, adding your own writing style, and the privacy guard.

Made your own extension? Open a pull request that adds it to this list.

**Only install extensions you trust.** An extension is code that runs on your Mac and sees the text you click it on. With the `network` entitlement it can send that text anywhere. PopKit asks before installing and tells you whether the extension uses the network.

## Privacy

- PopKit itself makes no network connections and has no analytics or telemetry. Only extensions you install, and only with the `network` entitlement, can reach the network.
- It reads your selection only when you make one, and never in password fields or excluded apps.
- Some apps (Slack, for one) don't tell other apps what is selected. For those, PopKit briefly presses ⌘C to read the selection, then restores your clipboard.
- Optional **Debug Logging** in the menu writes what PopKit saw (app, field type, which buttons it showed) to `~/Library/Logs/PopKit.log`. It never records your text.

## Known limits

- **Apps that hide their text fields.** Slack answers none of macOS's accessibility questions, so PopKit can read a selection there but can't tell a message box from read-only text. By default it assumes editable, so rewrite buttons also show on read-only Slack text, where pasting does nothing. A setting in General turns this off.
- **Keyboard layouts.** Copy and paste use the physical position of C and V on a US keyboard. On layouts that move those keys the shortcut can miss.
- **Secure input.** Apps that turn on secure keyboard entry, such as some terminals, may hide key events from PopKit.
- **Not a sandboxed or App Store app.** It can't be, because of the permissions it needs.
- **Supports a subset of the PopClip extension format.** See [what's not supported](docs/extensions.md#not-supported).

## Development

```bash
swift build
swift test
```

The tests need no network and no permissions. See [CONTRIBUTING.md](CONTRIBUTING.md) for the layout of the code and how to debug selection problems.

## License

[MIT](LICENSE)
