# Lasso

Lasso is a local macOS menu-bar app that turns a deliberate rectangular screen
capture into useful context for a coding agent. It keeps the selected pixels,
OCR/accessibility context, optional annotations, and (on the web) an optional
DOM fingerprint available to an MCP client on the same Mac.

Lasso does not continuously record the screen and never pushes a capture to an
agent by itself: the user captures deliberately, then the agent explicitly asks
for the newest capture over MCP.

![Lasso showing a rectangular capture with numbered pins, a capture note, tags, and local context.](https://github.com/user-attachments/assets/60477c93-9001-4f18-85e4-42df2421d920)

## Requirements

- macOS 14 or later
- A supported MCP client: Claude Code, Codex, or Cursor
- Screen Recording permission. Accessibility is optional and improves text
  context.

## Install from a release

1. Download `Lasso-<version>-macos.zip` from [Releases](../../releases).
2. Unzip it, move `Lasso.app` to `/Applications`, and open it.
3. Accept Screen Recording when macOS asks. Lasso opens its guided setup, where
   you can copy the MCP command for your client.
4. Use the default `Option-Space` shortcut, then drag a rectangle around the
   area you want the agent to see.

The release bundle includes the `lasso-mcp` executable used by the setup flow;
no separate developer checkout is required.

## Optional Chrome extension

The Chrome extension adds a DOM fingerprint (selector, visible text, and where
available the React component) to a capture made over a webpage. Screen capture
works without it.

To use it, open **Lasso → Setup → Richer context on the web → Open extension folder**.
In `chrome://extensions`, enable Developer mode, select **Load unpacked**, and
choose the revealed `extension` directory. Lasso registers its bundled Native
Messaging host when it starts, so reopening the app after moving it keeps the
host path current.

The extension is presently loaded unpacked; it is not distributed through the
Chrome Web Store.

## Privacy and data handling

Lasso keeps its data on your Mac. See [the privacy note](docs/PRIVACY.md) for
the storage location, retention policy, agent hand-off, and deletion steps.
Secret redaction is a useful safeguard, not a guarantee: do not capture
credentials or other highly sensitive material.

## Development

```bash
swift test
node --test extension/test/*.test.mjs
scripts/build-app.sh
```

`scripts/build-app.sh` reads the tracked [VERSION](VERSION) file and creates `build/Lasso.app` and a clean
`build/Lasso-<version>-macos.zip`. The archive is unpacked and code-signature
verified by the script before it reports success.

To notarize and staple a release, first store a `notarytool` keychain profile,
then run:

```bash
LASSO_NOTARIZE=1 LASSO_NOTARY_PROFILE=lasso-notary scripts/build-app.sh
```

## Security

Please read [SECURITY.md](SECURITY.md) before reporting a vulnerability. Do not
put credentials, screenshots, or other captured content in a public issue.

## License

Lasso is open source under the [MIT License](LICENSE).
