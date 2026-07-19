# Lasso

Lasso is a local macOS capture tool that gives coding agents deliberate visual,
textual, and web-context references while keeping the user in control.

## Language

### Captures

**Capture**:
A persisted visual context: its image, capture-level note, pins, and per-pin
notes form one immutable record.
_Avoid_: screenshot when the annotations and context matter

**Show last capture**:
A read-only presentation of the newest active Capture, exactly as it was
recorded. It neither performs a new screen capture nor creates a new record;
the detail view can navigate to adjacent active Captures. Recently Deleted
captures are excluded.
_Avoid_: Refresh last capture, recapture

**Recent capture**:
A Capture subject to the user’s automatic retention rule.
_Avoid_: temporary screenshot

**Kept capture**:
A Capture explicitly preserved by the user. It is excluded from automatic
retention and remains until the user deletes it. It can be marked during
annotation or from Capture History.
_Avoid_: favorite, archived screenshot

**Retention rule**:
The single user-selected lifetime for both Recent captures and Recently Deleted
captures, bounded by a fixed safety cap of 100 Recents. It defaults to seven
days and offers 1 hour, 1 day, 7 day, 30 day, or 90 day choices. It never
applies to Kept captures. Expired Recents are permanently deleted rather than
moved to Recently Deleted.
_Avoid_: history cleanup

**Capture History**:
A dedicated library window for browsing Captures as a chronological visual grid.
It supports continuously changing the thumbnail density and filters for All,
Recents, Kept, and Recently Deleted. Thumbnails show a discreet pin count;
full annotations appear only in the detail view. The detail view has a
collapsible Context section for capture metadata. Search covers OCR/DOM text,
Tags, capture notes, pin notes, application names, and window or page titles.
_Avoid_: menu popover, screenshot folder

**Capture package**:
A portable export of one Capture containing its original PNG, a rendered
annotated PNG, notes, pins, and available context in both human-readable
Markdown and machine-readable JSON.
_Avoid_: exported screenshot

**Batch export**:
A single ZIP containing several Capture packages and a root README summary.
It is created from a multi-selection in Capture History.
_Avoid_: merged screenshots

**Library settings**:
The user controls for Capture History: retention duration, storage visibility,
and clearing Recents or Recently Deleted. Clearing Recents moves them to
Recently Deleted after confirmation.
_Avoid_: capture settings

**Recently Deleted**:
The temporary holding area for user-deleted Captures, lasting for the current
Retention rule. A user can restore or permanently erase a Capture before expiry.
Restoration returns a Capture to its prior state: Recent or Kept. Moving a
Capture here offers a brief Undo; permanent erasure requires confirmation.
_Avoid_: permanent delete

**Tag**:
A user-defined label that can be applied to any number of Captures, and any
Capture can hold several Tags. Tags are free-form and reusable through typed
suggestions; they support filtering and grouped export. They are assigned in
the annotation step and remain editable in Capture History. The annotation
picker surfaces the five most recently used Tags before search and creation.
Tags with no associated Capture disappear from suggestions automatically.
_Avoid_: folder, single-category label
