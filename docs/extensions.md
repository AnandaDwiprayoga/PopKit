# Writing PopKit extensions

An extension adds buttons to PopKit's popup. It is a folder with a `Config.json` and a JavaScript file. PopKit supports a **subset of the PopClip extension format**: an extension that sticks to what this page documents runs unchanged in PopKit, and anything not documented here is not supported. PopKit is an independent project and is not affiliated with PopClip.

- [Quick start](#quick-start)
- [Folder layout](#folder-layout)
- [Config.json](#configjson)
- [The module](#the-module)
- [Globals](#globals)
- [`require`](#require)
- [`axios`](#axios)
- [Errors](#errors)
- [Options and secrets](#options-and-secrets)
- [Installing, updating, removing](#installing-updating-removing)
- [Testing from the command line](#testing-from-the-command-line)
- [Not supported](#not-supported)

## Quick start

```
Shout.popkitext/
├── Config.json
└── index.js
```

`Config.json`:

```json
{
  "name": "Shout",
  "description": "Replace the selection with its UPPERCASE form.",
  "icon": "AA"
}
```

`index.js`:

```js
module.exports = {
  actions: [
    {
      title: "Shout",
      icon: "AA",
      requirements: ["text", "paste"],
      code: async (input) => {
        await popclip.pasteText(input.text.toUpperCase(), { restore: true });
      },
    },
  ],
};
```

Install it with **Install Extension…** in the PopKit menu, select text in an editable field, and click the button. The folders in [`Examples/`](../Examples) are complete, working extensions.

## Folder layout

An extension is a folder. The name is up to you, and `.popkitext` is the convention. PopKit also accepts `.popclipext` folders, through the Install Extension… picker and the command line.

The extension's **id** is the `identifier` from `Config.json` if there is one, otherwise the folder name without its extension. The id names its saved settings and its Keychain entries, so keep it stable.

Everything the extension needs must be inside the folder. It can `require` any file in it, and nothing outside it.

## Config.json

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Shown in Settings and the install dialog. |
| `description` | no | One or two sentences, shown when installing and in Settings. |
| `icon` | no | The default icon for the extension's buttons. See [Icons](#icons). |
| `identifier` | no | Overrides the folder name as the id. |
| `entitlements` | no | `["network"]` lets the extension make web requests. Without it, [`axios`](#axios) refuses every request. |
| `module` | no | The JavaScript file that exports the actions. Defaults to `index.js`. |
| `options` | no | Settings the user can change. See [Options and secrets](#options-and-secrets). |

`name` is the only required key. A missing or invalid `Config.json`, or a `module` file that doesn't exist, makes the install fail with a message.

### Icons

An icon is one of:

- **Text or an emoji**: `"AA"`, `"✨"`. Keep it short.
- **An SF Symbol**: `"symbol:doc.on.doc"`.
- **A PNG file in the extension folder**: `"icon.png"`. The path is relative to the folder.

An action's own `icon` wins over the extension's `icon`. With neither, the button shows `•`.

## The module

The module file exports an object with an `actions` array. Each action is one button.

```js
module.exports = {
  actions: [
    {
      title: "Uppercase",           // the tooltip, and the name in the CLI
      icon: "AA",                   // optional, see Icons
      requirements: ["text", "paste"], // optional, defaults to ["text"]
      code: (input, options) => { /* … */ },
    },
  ],
};
```

### `requirements`

An action only appears when the selection meets all of its requirements.

| Requirement | Met when |
|---|---|
| `"text"` | There is selected text. |
| `"paste"` | The selection is in an editable field, so it can be replaced. |

An action that lists any other requirement is left out, and the reason is written to the extension's log. A list of just `["text"]` is the default.

PopKit decides whether a field is editable from the macOS Accessibility information the app provides. Some apps, Slack for one, don't provide it. For those apps PopKit guesses, according to the setting **Show rewrite buttons when an app won't say if text is editable** in Settings → General.

### `code(input, options)`

PopKit calls it when the button is clicked.

- `input.text` is the selected text, unmodified.
- `options` holds the current value of each option from `Config.json`, by `identifier`. Strings for `string`, `secret` and `multiple` options, booleans for `boolean` ones.
- It may return a Promise (or be an `async` function). PopKit waits for it, up to **30 seconds**, and shows a spinner on the button meanwhile.
- When it finishes, PopKit shows ✓. If it threw or rejected, PopKit shows ✗ and writes the message to the extension's log. See [Errors](#errors).
- If the action called [`popclip.showText`](#popclipshowtexttext-options) the text stays on screen instead of the ✓.

An extension runs one action at a time. Clicking one of its other buttons while one is running does nothing.

## Globals

### `popclip`

`popkit` is an alias of the same object.

#### `popclip.pasteText(text, options)`

Replaces the selection with `text` by pasting it. Returns a Promise that resolves once the paste has been sent and, with `restore`, the clipboard has been put back.

```js
await popclip.pasteText("new text", { restore: true });
```

With `{ restore: true }` the previous clipboard contents are put back about 400 ms later, unless something else wrote to the clipboard in the meantime. Without it, the pasted text stays on the clipboard. Use `restore: true` unless the user is meant to be able to paste again.

#### `popclip.copyText(text)`

Puts `text` on the clipboard.

#### `popclip.showText(text, options)`

Shows text in the popup instead of the buttons.

| Call | What the user sees |
|---|---|
| `showText(text)` | A short notice, hidden after about two seconds. |
| `showText(text, { preview: true })` | The text in a bubble. Clicking it pastes it over the selection if the selection is editable, and copies it otherwise. It stays until the user clicks elsewhere. |
| `showText(text, { style: "large" })` | A scrollable card with **Copy** and **Close** buttons. For long text. |

A typical rewrite action pastes by default and previews when the user holds ⌥ (see `popclip.modifiers`).

#### `popclip.openUrl(url)`

Opens a URL in the default app. Only `http:`, `https:` and `mailto:` URLs are opened. Anything else is ignored.

#### `popclip.modifiers`

Which modifier keys were held when the button was clicked: `{ shift, option, command, control }`, each a boolean.

```js
if (popclip.modifiers.option) popclip.showText(result, { preview: true });
else await popclip.pasteText(result, { restore: true });
```

#### `popclip.context`

`{ appIdentifier, appName }` of the app the text was selected in. For example `{ appIdentifier: "com.apple.TextEdit", appName: "TextEdit" }`.

#### `popclip.input`

`{ text }`, the same as the `input` argument to `code`.

### `print(...)`, `console.log(...)`

Write a line to the extension's log, which is shown in Settings → Extensions. `console.info`, `warn`, `error` and `debug` do the same. Objects are written as JSON.

### `setTimeout(fn, ms, ...args)`, `clearTimeout(id)`

As in a browser. There is no `setInterval`.

### `Promise`, `JSON`, and the standard language

The standard JavaScript language of the system's JavaScriptCore engine is available, including `async`/`await`, `Promise`, `Map`, regular expressions, `JSON`, `Math` and `Date`.

There is **no** `process`, `fetch`, `XMLHttpRequest`, `window`, `document`, `localStorage` or Node.js module. `process` is deliberately undefined: extensions commonly use `typeof process` to tell Node from PopClip, and PopKit follows PopClip.

## `require`

```js
const helper = require("./lib/helper.js");   // a file
const config = require("./config");          // ./config.js, then ./config.json, then ./config/index.js
const data = require("./data.json");         // parsed JSON
const axios = require("axios");              // the built-in HTTP client
```

- Paths must be relative (`./` or `../`) and stay inside the extension folder. A symlink that leads outside it is treated as missing.
- Modules are cached, so each file runs once.
- `module.exports` and `exports` work as in CommonJS.
- A missing file throws an error with `error.code === "MODULE_NOT_FOUND"`. Extensions use this to load an optional local file:

```js
let local = {};
try {
  local = require("./local.config.js");
} catch (error) {
  if (error.code !== "MODULE_NOT_FOUND") throw error;
}
```

The only bare module name that works is `"axios"`. Anything else throws `MODULE_NOT_FOUND`.

## `axios`

A small subset of [axios](https://axios-http.com/), enough for typical API calls. The extension must list `"network"` in `entitlements`.

```js
const axios = require("axios");

const response = await axios.post(
  "https://api.example.com/v1/rewrite",
  { text: input.text },                                   // an object is sent as JSON
  { headers: { authorization: "Bearer " + options.apiKey }, timeout: 15000 }
);
console.log(response.status, response.data);
```

**Calls:** `axios(config)`, `axios.request(config)`, `axios.get/delete/head/options(url, config)`, `axios.post/put/patch(url, data, config)`.

**Config:** `url`, `method`, `data`, `params` (added to the query string), `headers`, `timeout` (milliseconds, default 60 000).

**Request body:** an object is sent as JSON with `Content-Type: application/json` unless you set a content type. A string is sent as is, with `application/x-www-form-urlencoded` unless you set one.

**Response:** an object with

- `status`: the HTTP status code,
- `headers`: the response headers, with lowercase names,
- `data`: the body, parsed if it is JSON and a string otherwise,
- `config`.

**Failures:** the promise rejects, as in axios, for any status outside 200–299 and for network errors. The error has `message`, `config`, `isAxiosError: true` and a `code`. For an HTTP error it also has `error.response.status`, `error.response.data` and `error.response.headers`. Without a response, the codes are:

| `error.code` | Meaning |
|---|---|
| `ECONNABORTED` | The request timed out. `message` is `timeout of Nms exceeded`. |
| `ERR_NETWORK` | The connection failed. |
| `ERR_ENTITLEMENT` | The extension doesn't have the `network` entitlement. No request was made. |
| `ERR_INVALID_URL` | The URL isn't `http:` or `https:`. |

Redirects are followed. Cookies are not stored or sent.

Not supported: `axios.create`, interceptors, cancellation, `responseType`, uploads and progress events.

## Errors

If `code` throws or its Promise rejects, the button shows ✗ and the error message is written to the extension's log.

**To send the user to the extension's settings**, for example when an API key is missing or was rejected, throw an error whose message starts with `settings error`:

```js
if (!options.apiKey) throw new Error("settings error: the API key is missing");
```

PopKit opens Settings → Extensions with your extension selected, and the log keeps the full message.

Errors while the module loads (a syntax error, a failed `require`) stop the extension from loading. The reason is shown at the top of its page in Settings and written to its log, and the extension adds no buttons until it loads.

## Options and secrets

Options are settings the user edits in Settings → Extensions. List them in `Config.json`:

```json
"options": [
  { "identifier": "apiKey", "type": "secret", "label": "API key",
    "description": "Stored in your Mac's Keychain." },
  { "identifier": "model", "type": "multiple", "label": "Model",
    "values": ["small", "large"], "valueLabels": ["Small (fast)", "Large"],
    "defaultValue": "small" },
  { "identifier": "hiddenTerms", "type": "string", "label": "Never send these words" },
  { "identifier": "verbose", "type": "boolean", "label": "Log requests", "defaultValue": false }
]
```

| `type` | Field | Value in `options` |
|---|---|---|
| `string` | A text field. | A string, `""` until set. |
| `secret` | A password field. The value is kept in the Keychain, never in a file. | A string, `""` until set. |
| `multiple` | A picker over `values`. `valueLabels` (or PopClip's `"value labels"`) gives each value a display name. | One of `values`. The first, or `defaultValue`, until changed. |
| `boolean` | A toggle. | `true` or `false`. |

`label` defaults to the `identifier`, and `description` is shown under the field. An option with any other `type`, such as a heading, is ignored.

Values are read each time a button is clicked, so changes apply immediately. They are stored per extension id, and **reinstalling or updating an extension keeps them**. Removing an extension deletes them, secrets included.

Secrets are stored in the login Keychain under the service `PopKit` and the account `<extension id>.<option identifier>`.

## Installing, updating, removing

- **Install Extension…** in the PopKit menu, or the **Install…** button in Settings → Extensions, opens a folder picker. A confirmation shows the extension's name, description, whether it can use the network, and a reminder that extensions run code.
- From a terminal: `PopKit --install <folder>`.
- Installing a folder whose id matches an installed extension replaces it and keeps its settings.
- Extensions are copied to `~/Library/Application Support/PopKit/Extensions/`. Editing the original folder afterwards changes nothing. Install it again.
- A built-in extension (Copy, Search) can be switched off but not removed, and an installed one can't take a built-in's id.
- In Settings → Extensions, the switch turns an extension off without removing it, and dragging reorders the buttons.

**Security.** An extension is code that runs on your Mac and sees every piece of text you click its buttons on. With the `network` entitlement it can send that text anywhere. Install extensions you trust, and read the code of ones you don't know.

## Testing from the command line

PopKit can run an extension without the popup. What the extension asks the screen to do is printed instead.

```bash
APP=PopKit.app/Contents/MacOS/PopKit

$APP --list Shout.popkitext
# 1. Shout  [text, paste]

$APP --run Shout.popkitext Shout "hello" --editable
# PASTE: HELLO

$APP --run Shout.popkitext 1 "hello" --editable --modifiers option
```

- The action is chosen by its title, or by its number from `--list`.
- `--editable` says the selection is in an editable field. Without it, `paste` actions still run, with a note.
- `--modifiers` takes `shift`, `option`, `command` and `control`, comma separated.
- Output lines are `PASTE:`, `COPY:`, `SHOW:`, `SHOW (preview):`, `SHOW (large):`, `OPEN:` and `SETTINGS:`. The extension's `print` output goes to stderr with a `[log]` prefix.
- Option values come from environment variables named `POPKIT_OPT_<IDENTIFIER in capitals>`, then the Keychain, then the defaults. For example `POPKIT_OPT_APIKEY=… $APP --run …`.
- Exit codes: `0` ran, `1` failed, `2` the extension asked for its settings.

`PopKit --probe <bundle id>` is for debugging the app, not extensions. See [CONTRIBUTING](../CONTRIBUTING.md).

## Not supported

PopKit implements the parts of the PopClip extension format described above. These are not supported, and extensions that rely on them won't work as written:

- `Config.plist` and `Config.yaml` (only `Config.json`), and actions declared in the config instead of in a module.
- Requirements other than `text` and `paste`, such as URL or regular-expression matching and per-app filters. An action that lists one is hidden.
- Reading or modifying PopClip's own settings and state, keyboard simulation, authentication flows, and any `popclip` function not listed above.
- Node.js modules other than the built-in `axios`, and `axios` features beyond those listed.
- Extension signing and an extension store. PopKit installs folders.
