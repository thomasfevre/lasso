# ADR 0013: Capture Library separates Recents, Kept, and Recently Deleted

## Context

Lasso started as a short-lived hand-off buffer. A visual history now needs to
support both privacy-minded automatic cleanup and deliberate preservation of
annotated capture work. Treating every Capture as equally ephemeral would lose
useful work; retaining everything indefinitely would make the local library and
its privacy guarantees unclear.

## Decision

Captures are immutable records in a Capture History. A user can mark one Kept,
which excludes it from automatic cleanup, or leave it Recent. One configurable
Retention rule applies to both Recents and manually deleted Captures, defaults
to seven days, and offers 1 hour, 1 day, 7 day, 30 day, and 90 day choices.
Recents are additionally capped at 100. Automatic expiry permanently deletes a
Recent. Manual deletion moves a Capture to Recently Deleted, from which it can
be restored to its former Recent or Kept state or permanently erased.

## Considered options

- A single retention bucket for every Capture would make “keep this” unreliable.
- An independent trash duration would add a second, surprising privacy setting.
- Editing past annotations would undermine the meaning of a Capture already
  handed to an agent, so History is organizational and read-only in v1.

## Consequences

- Capture persistence needs explicit lifecycle state and reversible deletion
  metadata rather than only append-and-purge rows.
- History can provide a Photos-like grid, filtering, tagging, grouping, and
  portable exports without mutating the original Capture.
- Kept captures require explicit user deletion and can outlive the retention
  setting by design.
