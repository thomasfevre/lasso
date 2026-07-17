# ADR 0012: Agent-requested capture uses a human nudge

## Context

Lasso was designed as a passive context provider: an Agent pulls Captures after
the user creates them. An Agent sometimes needs fresher spatial context to keep
an iterative task moving, but letting it open the Overlay would remove the
human's control and blur the security boundary around screen capture.

## Decision

Add an MCP tool, `request_capture`, that writes a short-lived row to a separate
SQLite `requests` table and immediately returns `{ "status": "requested", "id":
... }`. The Conductor polls that table and shows a dismissable menu-bar nudge.
Only a user action—the existing hotkey, Capture menu item, or clicking the
nudge—may open the Overlay.

Requests expire after five minutes. There is one shared pending intent across
all stdio Hub processes: duplicates and concurrent requests coalesce to the same
ID. The nudge therefore says “An agent” rather than attributing the request to a
specific client. A successful Capture clears requests that existed when it was
written; dismiss clears the displayed request.

## Preserved invariant

The Conductor remains the only production writer of the `captures` table.
`request_capture` never writes a Capture and never invokes the Overlay.

## Consequences

- The Agent must poll `get_latest_capture(after_id)` after receiving
  `requested`; a request is not proof that the user captured anything.
- Hubs gain narrowly scoped write access to the `requests` table while Capture
  storage and retention remain unchanged.
- The request channel is intentionally lossy and session-oriented: stale rows
  disappear, duplicate clients share one nudge, and there is no request queue.
