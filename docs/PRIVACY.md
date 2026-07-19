# Privacy

Lasso is designed to keep capture context local and under the user's control.
This document describes the current behaviour of version 0.1.x.

## What Lasso reads

- **Screen Recording** is required to create a rectangular capture that you
  deliberately start with Lasso's shortcut or menu item.
- **Accessibility** is optional. When granted, it can add the name, window
  title, and accessible text of the element under the capture.
- The optional Chrome extension can add a DOM fingerprint for the webpage under
  a deliberate capture. It has broad website access so it can work on the page
  you choose, but it communicates with Lasso only through Chrome Native
  Messaging on the same Mac.

Lasso does not continuously record the screen, use analytics, or send captures
to a Lasso-operated server.

## Local storage and retention

By default, captures are stored in `~/Library/Application Support/Lasso/` as a
local SQLite database and PNG files. You can move the library to another folder
from Settings. Settings always displays the folder currently in use. Recent
captures are kept for seven days by default and are capped at the newest 100.
You can change the duration to 1 hour, 1 day, 7 days, 30 days, or 90 days in
Settings. Captures marked Keep are excluded from automatic retention. Manually
deleted captures remain restorable in Recently Deleted for the same selected
duration. The store directory is owner-only and capture files are created with
owner-only permissions.

An MCP client reads this local store only when it invokes a Lasso tool. The
client may then transmit the returned capture to its own configured service;
that handling is governed by the client and provider you choose.

## Redaction

Before persisting a capture, Lasso attempts to redact recognised credentials in
both extracted text and the matching image regions. This is defence in depth,
not a promise that every secret will be recognised. Avoid capturing passwords,
private keys, tokens, financial information, or anything you cannot share with
your selected coding agent.

## Delete local data

Use History to remove individual captures, or Settings to clear all Recent
captures after confirmation. To remove the complete local library, note the
current Storage path in Settings, quit Lasso, then delete that folder. The
default path is `~/Library/Application Support/Lasso/`.

Browser pairing credentials are separate from the capture library. Lasso keeps
its side in the macOS Keychain and Chrome keeps its side in extension storage.
Use Revoke all browser pairings from Lasso's menu, then remove the extension
from Chrome if you want to remove that integration completely.

To remove the optional Chrome integration, remove the unpacked Lasso extension
from `chrome://extensions`. The Native Messaging manifest is located at
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/xyz.allez.lasso.host.json`.
