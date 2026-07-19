# Plan: Capture Library

> Source PRD: product-design session on 2026-07-16

## Architectural decisions

- **Capture identity**: a Capture’s image, note, pins, and contextual payload are
  immutable once recorded. Library actions change organization metadata only.
- **Lifecycle**: active Captures are either Recent or Kept. Manually deleted
  Captures move to Recently Deleted; automatic expiry permanently removes only
  Recents. Recently Deleted uses the same user-selected duration as Recents.
- **Retention**: the one user-facing duration defaults to seven days and offers
  1 hour, 1 day, 7 days, 30 days, and 90 days. Recents are additionally capped
  at 100; Kept Captures are excluded from automatic retention.
- **Tagging**: Tags are reusable, user-defined, many-to-many labels. They can
  be assigned during annotation and edited from History; unused Tags disappear
  from suggestions.
- **MCP boundary**: agent-facing “latest” and recent-capture reads include only
  active Captures, never Recently Deleted ones.
- **Presentation**: History uses a dedicated native window with Photos-like
  browsing interactions while keeping Lasso’s dark glass visual language.
- **Export**: a Capture package contains `original.png`, `annotated.png`, a
  human-readable Markdown summary, and machine-readable JSON. Batch export is
  one ZIP containing packages plus a root README.

---

## Phase 1: Review the latest Capture

**User stories**:

- As a user, I can choose **Show last capture** and review the newest active
  Capture exactly as it was recorded.
- As a user, I can inspect its image, pins, pin notes, capture note, and
  contextual metadata without creating another Capture.

### What to build

Replace the current refresh-as-recapture command with a read-only Capture
detail presentation. It opens the newest active Capture, supports moving to its
previous or next active neighbor, and renders pins as an overlay with a
corresponding note list and a collapsible Context section. It remains disabled
when no active Capture exists.

### Acceptance criteria

- [ ] Choosing Show last capture creates no Capture row and no image file.
- [ ] The detail view reproduces the original image, capture note, pins, and
  pin notes of the selected Capture.
- [ ] Previous/next navigation excludes missing or deleted Captures.
- [ ] Unit tests cover active-Capture lookup and no-write behavior; a bundled
  app smoke test proves the menu action opens the persisted Capture.

---

## Phase 2: Browse Capture History

**User stories**:

- As a user, I can visually browse my active Captures in a dedicated History
  window.
- As a user, I can zoom the thumbnail density in and out and open any Capture
  in detail.

### What to build

Add Capture History as a dedicated library window with a chronological,
newest-first grid grouped by day. The initial library browses active Captures;
the grid supports continuous thumbnail density changes and shows a subtle pin
count rather than drawing each pin at thumbnail size. Opening an item uses the
same immutable detail presentation from Phase 1.

### Acceptance criteria

- [ ] The menu-bar History action opens a native library window rather than a
  menu popover.
- [ ] The grid loads retained Captures newest-first, groups them by day, and
  updates thumbnail density smoothly.
- [ ] Each thumbnail exposes a pin-count affordance when applicable.
- [ ] Selecting a thumbnail opens its complete read-only detail.
- [ ] Tests cover chronological ordering, grouping inputs, and thumbnail/image
  lookup safety.

---

## Phase 3: Manage lifecycle and retention

**User stories**:

- As a user, I can keep an important Capture indefinitely or remove one without
  immediately losing it.
- As a user, I can choose how long ordinary Captures and my trash are kept.

### What to build

Introduce the library lifecycle model end-to-end: Recent, Kept, and Recently
Deleted. Add the Keep control to annotation and detail views; add reversible
manual deletion, restoration to the prior state, and confirmed permanent
deletion. Add Settings with capture shortcut/permission status, library storage
visibility, the single retention choice, and safe bulk-cleanup actions.

### Acceptance criteria

- [ ] A Capture marked Keep is never removed by age or the 100-Recent cap.
- [ ] Manual delete offers Undo and moves the Capture to Recently Deleted.
- [ ] Restore returns a Capture to its prior Recent or Kept state.
- [ ] Automatically expired Recents are permanently removed; manual trash uses
  the same configured duration as Recents.
- [ ] Settings offers 1 hour, 1 day, 7 days, 30 days, and 90 days, with seven
  days as the default.
- [ ] Clearing Recents asks for confirmation and moves them to Recently Deleted.
- [ ] Migration and lifecycle tests cover old stores, image cleanup, retention,
  recovery, and active-only MCP reads.

---

## Phase 4: Tag and find captures

**User stories**:

- As a user, I can classify a Capture quickly while I annotate it.
- As a user, I can find captures by project/review context and organize them
  after the fact.

### What to build

Add a multi-tag picker to annotation: it suggests the five most recently used
Tags, searches existing Tags, and creates a new Tag with typed text plus Enter.
Expose tag editing and tag filters in History, alongside targeted search over
Tags, capture notes, pin notes, application names, and window/page titles.

### Acceptance criteria

- [ ] Annotation can assign multiple existing or newly created Tags without
  slowing the pin/note workflow.
- [ ] History can filter by Tag and search only the agreed targeted fields.
- [ ] A Capture can carry multiple Tags; a Tag can label multiple Captures.
- [ ] Unused Tags no longer appear in annotation suggestions.
- [ ] Tests cover tag creation, reuse, assignment, filtering, search, cleanup,
  and migrations.

---

## Phase 5: Export and share selections

**User stories**:

- As a user, I can send one annotated Capture in a portable form.
- As a user, I can select several review Captures and send them together.

### What to build

Add standard macOS multi-selection to History and export actions for a single
Capture or a selection. Render an annotated image without modifying the stored
original, generate the Markdown and JSON representations, and assemble a batch
ZIP with a root README. Offer both Save export and the native macOS Share Sheet
for the same artifact.

### Acceptance criteria

- [ ] A single Capture package contains the original image, annotated preview,
  Markdown, and JSON with equivalent pins/notes/context.
- [ ] `⌘`-click multi-selection exports one ZIP containing one package per
  selected Capture and a root README.
- [ ] Share uses the native macOS Share Sheet for the generated export.
- [ ] Export never mutates the stored Capture or exposes Recently Deleted items.
- [ ] Tests validate package contents, annotation rendering inputs, batch layout,
  and failure cleanup; manual QA validates Save and Share on-device.
