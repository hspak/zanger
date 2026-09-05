# Zanger Architecture

Zanger is written for Zig 0.16.0 and supports x86_64 Linux and aarch64 macOS. It
uses libvaxis/vxfw 0.6.0 for the terminal UI, inotify or kqueue for live
directory updates, and zeit 0.9.0 for local status-bar timestamps.

## System map

The executable is split into a small entry point and focused modules:

| File | Responsibility |
|---|---|
| [`src/main.zig`](src/main.zig) | Creates the terminal app and stable heap-allocated model, then enters the vxfw loop |
| [`src/Model.zig`](src/Model.zig) | Owns interactive state, navigation transactions, commands, deletion, and rendering |
| [`src/Model/Pane.zig`](src/Model/Pane.zig) | One pane's owned listing or preview, its row widgets, and wheel capture |
| [`src/Model/PendingView.zig`](src/Model/PendingView.zig) | Stages all-or-nothing pane content and related model state |
| [`src/Model/Row.zig`](src/Model/Row.zig) | Stable row widgets for click identity, clipping, and metadata styling |
| [`src/Model/Preview.zig`](src/Model/Preview.zig) | Structured text, notice, spacer, and metadata rows for the children pane |
| [`src/Model/cursor.zig`](src/Model/cursor.zig) | Pure HERE cursor transitions |
| [`src/Model/input.zig`](src/Model/input.zig) | Key-to-browse-action policy used by root capture |
| [`src/Model/interaction.zig`](src/Model/interaction.zig) | Actionable mouse-event recognition and double-click tracking |
| [`src/Model/scheduler.zig`](src/Model/scheduler.zig) | Pure deferred-preview scheduling state |
| [`src/Model/FileMetadata.zig`](src/Model/FileMetadata.zig) | One file's native `statx`/`fstatat` metadata |
| [`src/Model/FileMetadata/`](src/Model/FileMetadata/) | Target-isolated Linux and macOS metadata queries |
| [`src/Model/IdentityCache.zig`](src/Model/IdentityCache.zig) | Cached UID/GID to account-name resolution |
| [`src/Model/format.zig`](src/Model/format.zig) | Pure permission-bit, size, and timestamp formatters |
| [`src/file_system.zig`](src/file_system.zig) | Builds and owns directory snapshots, entries, selection state, and preformatted rows |
| [`src/file_system/symlink.zig`](src/file_system/symlink.zig) | Relative symlink queries, with a Linux stat workaround under `symlink/` |
| [`src/Watcher.zig`](src/Watcher.zig) | Platform-neutral transactional HERE-watch facade |
| [`src/Watcher/`](src/Watcher/) | Linux inotify and macOS kqueue watcher backends |
| [`src/platform.zig`](src/platform.zig) | Supported-target checks, desktop opener policy, and POSIX child reaping |
| [`src/platform/`](src/platform/) | Target-isolated desktop opener policy |
| [`src/command.zig`](src/command.zig) | Resolves unique command prefixes into a closed command enum |
| [`src/profile.zig`](src/profile.zig) | Runs deterministic filesystem, layout, and surface-composition performance workloads |

At runtime the dependency direction is:

```text
main
 ├─ vxfw.App
 └─ Model
     ├─ Pane / PendingView / Preview / IdentityCache
     ├─ cursor / input / interaction / scheduler
     ├─ file_system.Listing
     ├─ Watcher
     ├─ command
     ├─ zeit.TimeZone
     └─ vxfw widgets and surfaces
```

`main` reads the starting working directory, user, hostname, and `TZ`/`TZDIR`. The `Model` is
allocated once on the heap because vxfw widget identity includes the address of
its `userdata`; moving the model after initialization would invalidate focus and
event-routing identities. `Model.init` creates the watcher, loads the local time
zone, initializes the three stable panes and command field, and installs the
first anchored view. Empty `TZ` uses UTC; named zones and absolute zone-file
paths are adapted to zeit's interfaces. Failed timezone loading falls back to
UTC, while allocation failures propagate. `Model.deinit` releases its resources.

## The anchored three-pane model

In this document, **HERE** or **CWD** means Zanger's current center path. It is
not necessarily the process working directory after startup.

The center pane is the source of truth. PARENT and CHILDREN are projections of
its path and the model's logical `HereCursor`:

```text
                              selected entry
                                    │
                                    ▼
PARENT                         CWD / HERE                      CHILDREN
dirname(C)                 listing for path C          projection of C/entry
    │                              │                            │
    └─ highlight basename(C)       └─ model cursor anchor       ├─ directory listing
                                                               ├─ text contents
                                                               ├─ notice + metadata
                                                               └─ empty placeholder
```

The model maintains these invariants after every committed operation:

1. HERE owns a readable absolute directory path `C` and is the only pane that
   accepts keyboard and wheel navigation; side-pane row clicks translate into
   anchored HERE navigation.
2. PARENT is absent at `/`. Otherwise, when readable, it represents
   `dirname(C)` and its optional `cwd_index` identifies `basename(C)` when that
   entry is visible. A hidden current directory can have no parent marker.
3. CHILDREN is derived from HERE's cursor. A directory — including a
   symbolic link to one — produces a listing or an empty-directory
   placeholder, a text file produces its rendered contents, and any other
   regular file or file symbolic link produces the non-text notice followed
   by metadata for the resolved file. Side panes accept mouse navigation only:
   clicking a parent row ascends into the parent directory with the clicked row
   selected as HERE's cursor (any row kind qualifies), and single-clicking a
   row in a CHILDREN directory listing promotes that listing to HERE with the
   clicked row selected. Keyboard browse interaction remains HERE-only.
4. Every non-empty pane has a valid `ListView` cursor and a row-widget array
   parallel to its displayed content.
5. Selection bitsets have one bit per listing entry. Selection follows a
   directory as its listing moves between pane roles.
6. Any current watcher targets HERE, never whichever widget currently has
   focus. It can be temporarily absent after an invalidation until re-arm.
7. Drawing performs no filesystem I/O and no persistent allocation.

### Roles are ownership, not focus

`PaneRole` is an enum with `parent`, `here`, and `children` values. It gives
type-safe indices to the homogeneous pane arrays and identifies the source and
destination of listing transfers. It does not represent an active pane.

Browse-mode focus always belongs to HERE's `ListView`. Command mode temporarily
focuses the persistent `TextField`; leaving command or confirmation mode queues
a focus request back to HERE. In browse mode, Tab and Shift-Tab are consumed as
no-ops. PARENT and CHILDREN never draw active cursors, and side-pane row clicks
navigate without taking focus. PARENT's `cwd_index` is an independent location
marker, not a focus cursor.

## Transactional view replacement

Navigation, rebuilds, hidden filtering, deletion refreshes, and watcher refreshes
can require several listings and previews to change together. Installing those
pieces one at a time would allow allocation or filesystem failures to leave the
panes describing different paths. `Model` coordinates a `PendingView` with an
optional `Watcher.Pending` to provide the transaction.

Each pane owns exactly one tagged `Pane.Content`: empty, a directory listing, or
a preview. `PendingView` mirrors that ownership as three `PendingPane` values,
keeping every staged payload beside the state and deferred mutation that apply
to it:

| Staged state | Purpose |
|---|---|
| `panes[3].content` | One tagged payload for each pane role |
| `panes[3].cursor` / `panes[3].cwd_index` | Framework cursor and stable PARENT marker installed with that payload |
| `panes[3].listing_source` | Live source role when a listing is borrowed for transfer |
| `panes[3].directory_empty_transfer` | Deferred mutation kept beside its borrowed listing |
| `cursor_status` / `preview_error_name` | Model-level CHILDREN state committed with the panes |

The replacement flow is:

```text
navigation / rebuild / refresh request
        │
        ├─ derive transfer and restoration mechanics from `ViewTransition`
        ├─ prepare a platform watch when the path or re-arm policy requires it
        ├─ construct required listings and previews
        ├─ validate every proposed listing transfer
        ├─ restore HERE cursor and selections when requested
        ├─ allocate row widgets and the next status message
        ├─ reserve retired-row tracking capacity
        │
        └─ no fallible work remains; commit
                 │
                 ├─ apply deferred state to transferred listings
                 ├─ commit the candidate watch, when present
                 ├─ detach reusable listings from their old panes
                 ├─ replace all three pane payloads
                 └─ release unused staged content
```

Before commit, an error deinitializes the pending view, cancels any prepared
watch, and leaves the live view untouched. During commit, ownership is moved,
not copied. A transferred source pane is detached before replacement, and an
installed staging slot is cleared so deferred cleanup cannot free its new
owner's listing. Row retirement uses capacity reserved during preparation, so
commit cannot free widget userdata still referenced by vxfw's previous frame.

### Listing transfers

Many path changes can reuse a snapshot that the UI already owns:

| Operation | Existing listing | New role |
|---|---|---|
| Descend or promote CHILDREN | old HERE | PARENT |
| Ascend or pick a PARENT row | old HERE | CHILDREN |
| Watcher refresh | old PARENT | PARENT |
| Deletion refresh | old PARENT | PARENT |

Expected path relationships are validated before a transfer is accepted. Every
new HERE snapshot is read after the destination watch has been prepared. CHILDREN
is unwatched, so its cached entries cannot establish the destination's current
contents. Descent and mouse promotion use a matching cached listing only to
restore selection, while transferring old HERE into PARENT.

Listings moving from HERE into a side pane retain their selection bits. When an
navigation or refresh rereads a snapshot as the new HERE, selection is restored
by exact entry name using a temporary hash set of selected names. Same-directory
replacement preserves the viewport when it still contains the cursor; otherwise
`ListView.jumpToItem` reveals the cursor.

Cursor movement is intentionally smaller than a full view transaction. The
model owns one `HereCursor` (`entry` or `none`). Upward directory navigation is a
separate action, with no synthetic cursor row. The model projects
that state into vxfw's HERE `ListView` through one application boundary.
Movement updates the logical cursor immediately, leaves the last committed
CHILDREN content visible, and schedules `syncRight` to replace only CHILDREN
after input settles.

Whenever CHILDREN must be built, full replacement and `syncRight` call the same
`prepareChildren` routine and receive a `PreparedChildren`; full replacement
also has an explicit listing-transfer fast path. `syncRight` combines that
result with staged row widgets, status text, and row-retirement capacity before
the live CHILDREN pane or HERE's directory-emptiness annotation changes. The
scheduler is also tagged: dirty work always has an already queued servicing
tick, while an obsolete queued tick is represented explicitly as harmless
stale work.

## Filesystem snapshots and ownership

`file_system.Listing` owns a complete, sorted snapshot of one directory. It does
not synthesize `.` or `..`; upward navigation is a model operation.

Snapshot construction opens the directory once and consumes it through batched
`Io.Dir.Reader` calls backed by a 32 KiB buffer. Zig lowers those batches to
Linux `getdents64` or Darwin `getdirentries`; starting in the already-reading
state avoids rewinding the newly opened directory. Ordinary entry kinds come
from those batches and do not require a separate `stat`; `.unknown` kinds get a
relative, non-following `Io.Dir.statFile` lookup. Symbolic links use
`Io.Dir.readLink` for their displayed target and `Io.Dir.statFile` for directory
classification on macOS. Linux retains a type-only `statx` wrapper because
Zig 0.16's `statFile` panics on `ENAMETOOLONG` during symlink resolution, including
valid short input names. A target-resolution failure such as a
dangling link leaves the entry visible but non-navigable; failure to read or
store the target still fails snapshot construction.

Each listing owns:

- entries sorted with in-place pdqsort;
- names and link targets stored in one listing-specific arena;
- a dynamic selection bitset and cached selected count;
- preformatted display rows held in one contiguous allocation.

The cached selected count keeps status rendering constant-time. Row strings are
updated in place when selection or known directory emptiness changes. Listing
teardown bulk-frees its owned slices and arena chunks rather than freeing each
entry separately.

Directory rows contain names or `link -> target` text. Directories are blue and
bold, symbolic links are teal, and selection overrides those styles with yellow
and bold. A grapheme-aware clipped row renderer stops once the pane width is
filled, so a long off-screen link target does not add work to every frame.

### Metadata previews and identity caching

A regular-file preview first reads up to 128 KiB and classifies that prefix: a
NUL byte or invalid UTF-8 marks it as binary. Text files render one preview line
per source line instead, with tabs expanded, control characters dropped, and a
truncation marker for oversized files. At most 1,024 source lines are retained,
and their sanitized bytes share one contiguous allocation rather than one
allocation per line; empty files preview as a placeholder message. Binary files
keep the metadata sheet under a dimmed italic notice
reading "non-text files are not rendered", styled like the empty-directory
placeholder. Non-regular files go directly to metadata. A nonblocking open and
descriptor kind check also handle replacement by a FIFO between stat and open;
the native open is needed because `Io.Dir.OpenFileOptions` has no general
nonblocking flag. Bounds and debouncing limit repeated preview work, but a
regular-file read on a slow filesystem can still delay the UI thread.

Preview rows carry their render meaning directly as `text`, `notice`, `spacer`,
or `field { label, value }`. Rendering switches on that tag; it never infers a
metadata field from a row index or a colon in display text. Tests can therefore
query fields by label while a separate layout test protects their order.

Symbolic links render like their targets: content reads and the sheet's native
stat call resolve through the link (the bottom status bar keeps describing the
link itself). A dangling link therefore previews as an unavailable target.

A binary file's metadata sheet formats name, type, Unix mode bits, owner/group,
size, modification time, writability, and link count. Ordinary files reuse
metadata already loaded for the bottom status when available; symbolic links
load the resolved target's metadata separately.
User and group names are resolved through `getpwuid_r` and `getgrgid_r` and
cached by numeric ID because NSS may consult services outside local files.

The detailed preview renders its timestamp in UTC. The compact browse status
uses the model's cached local `zeit.TimeZone`; `format.statusTime` converts the
filesystem nanosecond timestamp with zeit and renders an `ls`-style local time.
If the local zone cannot be loaded at startup, the model uses UTC; allocation
failure still aborts initialization.

## Interaction flows

### Navigation and selection

- `j`/`k`, Ctrl-N/Ctrl-P, and arrows move HERE.
- Ctrl-D/Ctrl-U move by half of the visible HERE rows.
- `g`/`G` jump directly to the first or last entry.
- Enter or `l` descends into a non-empty directory. On any other entry it first
  follows symlinks and accepts only a regular file without execute bits, because
  desktop openers may execute what they are given. Accepted paths are spawned
  detached through `xdg-open` on Linux or `/usr/bin/open` on macOS, and their
  children are collected on a later recurring model tick. Refused entries flash
  `cannot open executables`; spawn failures flash `open:` plus the error name,
  while action-level failures use the bottom status message.
- `h` or Backspace ascends and keeps the directory just left under HERE's
  cursor.
- Space toggles HERE's cursor entry and advances for bulk selection.
- Ctrl-H toggles hidden entries and performs a full anchored rebuild.
- `q` exits from browse mode; `:` enters command mode.

An empty directory shown in CHILDREN remains a preview and cannot be entered or
promoted; initialization, recovery, or filtering can still leave HERE with zero
visible entries. A no-op click or jump does not rebuild CHILDREN. Side-pane
clicks navigate: a parent row ascends into the parent directory with that row
picked as the center cursor, and a row click in a CHILDREN directory listing
promotes that listing to HERE with the clicked row selected. Preview rows
consume left presses but do not navigate. A second left press on the same HERE
row within 400 ms descends when that row is a directory and otherwise applies
the same regular-file opener policy. Every view transaction clears
pending-click state so presses cannot pair across listings.
Blocked input — refused opens, empty directory descents, ascent past `/`, or
deletion with nothing selected — flashes a red notice beside the header path
for three seconds, cleared on a recurring model tick. Any key press or mouse press
dismisses the notice immediately; mouse releases and motion do not. Side
listings can retain selections for later reuse, but selection and deletion
operations always target HERE.

Stable `Row` widgets provide click identity because vxfw `ListView` has no
click-to-select support and its scroll type is private. A HERE row click moves
the cursor. Pane wrappers capture wheel presses before `ListView` applies its
own viewport-only scrolling; HERE moves by one item and side panes consume the
input without changing state. Same-direction press reports within one short
coalescing window contribute only one move; release-shaped reports are consumed
without moving.

### Debounced CHILDREN preview

Filesystem work is kept out of continuous cursor input:

```text
cursor event
    ├─ update HERE cursor
    ├─ request an immediate cursor/status redraw
    ├─ mark CHILDREN stale and retain its committed content
    ├─ show the current entry name with a pending status
    ├─ move the preview deadline 40 ms forward
    └─ queue or revise the servicing timer
             │
             └─ timer after input settles
                    ├─ build only the final preview
                    ├─ install it transactionally
                    └─ request another redraw
```

The preview timer is separate from the recurring watcher timer. Forty
milliseconds spans normal 30–60 Hz key-repeat intervals, so continued input can
move the deadline before synchronous work begins. Only the final cursor target
incurs a directory scan, metadata request, or account lookup. The cursor and
pending name paint immediately; full bottom details change with the same commit
as CHILDREN, while entry and selection counts remain live. Watcher refresh stays
postponed for the same dirty interval.

### Commands and modes

The model has three modes: `browse`, `command`, and `confirm`. They are variants
of one tagged `Mode`; only `confirm` carries the pending deletion count. Pressing
`:` clears and focuses the persistent command `TextField`. Escape returns to
browse mode. Enter gives the field's temporary owned value to `submitCommand`,
after which vxfw frees it. Header flash state similarly keeps its owned text and
deadline together in one optional value.

The parser returns one of four closed commands: `help`, `hidden`, `delete`, or
`quit`. Any unambiguous prefix is accepted, so `d`, `dele`, `he`, `hi`, and `q`
resolve as expected. `h` is rejected because both `help` and `hidden` match.
While typing a strict unique prefix, the status row displays the assumed full
command as a dimmed hint, such as `→ :delete`.

Commands accept no arguments. In particular, `hidden` is a simple toggle.
Unknown, ambiguous, empty, and extra-argument inputs return to browse mode with
a status message.

### Deletion

`:delete` enters confirmation mode for HERE's selected entries, or HERE's
cursor entry when there is no selection. The model copies target paths before
mutating the filesystem. Real directories are recursively removed; symbolic
links are unlinked even when they resolve to directories, so their targets are
never traversed.

`y` or `Y` confirms; `n`, `N`, or Escape cancels. Confirmation is modal, so all
other input is consumed and watcher refresh waits until the mode ends.

Successful partial work is retained. After deletion, the anchored view is
refreshed, the cursor keeps its row when possible, and the status reports the
number deleted and, if applicable, the first failure.

## Live directory watching

`Watcher` presents one transactional interface over two backends. Linux owns a
process-lifetime, close-on-exec, nonblocking inotify descriptor. macOS owns a
close-on-exec kqueue plus one `O_EVTONLY | O_CLOEXEC` directory descriptor per
prepared or current watch. At most one watch is current, and it always
corresponds to HERE. Both backends detect child-list changes, deletion or rename
of HERE, and unmount/revocation; Linux also reports inotify queue overflow.

libvaxis 0.6.0 does not expose its internal poll set through `vxfw.App`, so the
model schedules a recurring 150 ms vxfw tick. An idle tick performs one
nonblocking drain and never scans a directory. All queued changes are reduced
to the strongest required action:

- `none`: no visible change;
- `content`: refresh the anchored snapshot;
- `rearm`: refresh and install a replacement watch.

Events from retired watches are ignored. inotify includes child names, so Linux
can drain hidden-name events without dirtying HERE when hidden files are
disabled. `EVFILT_VNODE` identifies only the changed directory, so macOS
conservatively refreshes after a hidden-only mutation; the listing filter still
keeps hidden entries invisible. Event storms are coalesced into one refresh,
and refresh is postponed while confirmation is active or a cursor preview is
dirty so watcher work does not interrupt either operation. Queue overflow or a
self-invalidating event forces a full refresh and re-arm.

The model coordinates watcher ownership with `PendingView`: navigation prepares
a candidate directory watch when required, pane preparation runs, and only a
successful view commit makes that watch current and retires the previous
descriptor. Rollback cancels the candidate.

When rebuilding the anchored view fails because HERE disappeared or became
unwatchable, the pending refresh is dropped and the model re-anchors at the
nearest surviving ancestor, reporting what vanished. Later filesystem events
schedule fresh refreshes, so failures never repeat on a timer. Replaced row
widget arrays are retired until the next draw instead of freed at commit,
because vxfw hit tests against the previous frame's surface tree and input
events can share one queue batch with a commit. Retired rows consume presses
without acting unless their address still belongs to the pane's active row array.

## libvaxis and vxfw integration

libvaxis has two layers:

```text
┌────────────────────────────────────────────────────────┐
│ vxfw widget framework: App, Widget, Surface, ListView  │
├────────────────────────────────────────────────────────┤
│ vaxis terminal core: Window, Cell, Style, Key, Mouse   │
└────────────────────────────────────────────────────────┘
```

The core layer handles terminal I/O, cell grids, key and mouse decoding, and
Unicode display width. vxfw builds a value-based widget tree on top. The app
owns all durable state; widgets are lightweight views over stable userdata.

### Widget identity and surfaces

A `vxfw.Widget` contains a userdata pointer plus optional capture/event handlers
and a draw function. Identity is the combination of the userdata and draw
function pointers. A widget without an event handler cannot receive focus.

Every draw returns a fresh `Surface` containing a size, owning widget identity,
optional cursor, optional cell buffer, and positioned child `SubSurface`s.
Containers commonly use an empty cell buffer and compose children. A non-empty
buffer must contain exactly `width * height` cells.

The widgets Zanger relies on are:

| Widget | Use in Zanger |
|---|---|
| `Text` / `RichText` | Header, previews, status, styled metadata, and command hints |
| `TextField` | Persistent command editor and submit callback |
| `ListView` | Visible-row construction, cursor, and viewport management |
| `Padding` | Horizontal pane padding |
| `FlexRow` | Equal-width pane layout and status-row composition |

`ListView.Builder` invokes Zanger's row builder only for visible indices.
Persistent row strings and stable `Row` userdata are prepared beforehand; the
builder only wraps them in frame-local surfaces.

### Event propagation and focus

For keyboard and focus events, vxfw dispatches along the focused-widget path
retained from the last rendered surface tree. Mouse events hit-test that same
tree to derive their path. Both paths dispatch in three phases:

```text
root ──capture──▶ focused target ──bubble──▶ root
```

Propagation stops when a handler consumes the event. `Model` routes all keys in
root capture using its current mode. Browse actions update the logical cursor
and invalidate CHILDREN together; remaining browse keys go to HERE's `ListView`.
Command keys are forwarded to the persistent `TextField` with target-phase
semantics. Confirmation consumes all input. This routing remains correct when
several keys arrive before vxfw applies a queued focus request. Event adapters
own consumption, redraw, and the single action-level error report.

Mouse adapters use shared interaction predicates to accept only actionable
presses. One `DoubleClickTracker` covers HERE rows; it tags the
target and invalidates its view generation after every committed replacement,
so releases, motion, different targets, and presses from an old view cannot
complete an action.

`requestFocus` queues a command rather than changing focus immediately. vxfw
sends focus-out/focus-in and applies the new target before the next layout.
Input batches are drained before those focus commands apply. The `TextField`
remains alive for the entire model lifetime even when command mode is not drawn.

Keys are Unicode codepoints plus modifier bits; special keys use named
constants. Mouse coordinates are cell-based. All text widths are measured with
`DrawContext.stringWidth`, never byte length, so grapheme clusters and wide
characters lay out correctly.

### App loop and frame arena

`vxfw.App.run` owns terminal setup, the event loop, timers, focus and mouse
handlers, rendering, and one `ArenaAllocator`. On a requested redraw it resets
that arena with `.free_all`, lays out the root widget, updates focus and hover
state, renders the resulting surface tree, and retains surface references only
until the next redraw. The arena is deinitialized when the app exits.

The application requests a 120 Hz vxfw cadence, bounding its frame-quantized
input and timer scheduling contribution to about 8.3 ms. Rendering remains
demand-driven, although vxfw still wakes to service its loop at that cadence.
An event-driven wake-up would avoid the periodic idle work, but vaxis 0.6.0 does
not expose that loop policy to applications.

`DrawContext.arena` therefore has exactly frame lifetime. Zanger allocates
temporary widgets, formatted status strings, segments, cells, and surfaces from
it without individual frees. Anything referenced across events or redraws must
instead use the model allocator or a listing-owned arena. vaxis does not expose
an `App` option for changing this reset policy; the profiling harness therefore
uses the same `.free_all` reset between measured frames.

Nested layout widgets may create short-lived child arenas backed by the frame
arena. Releasing one returns no memory to the general-purpose allocator; the
outer frame reset remains the true reclamation boundary.

### Render tree

The root surface uses an empty buffer and positions these children:

```text
root Surface
├─ `user@hostname /absolute/here/path` header
├─ blank spacer row
├─ FlexRow (terminal height - 3)
│  ├─ horizontal Padding → PARENT ListView
│  ├─ horizontal Padding → HERE ListView
│  └─ horizontal Padding → CHILDREN ListView / preview
└─ bottom row
   ├─ browse: message, or compact entry metadata + entry/selection counts
   ├─ command: `:` + TextField + optional completion hint
   └─ confirm: deletion prompt
```

At very small terminal sizes, the model preserves the header and bottom row and
constrains pane content. An empty HERE surface keeps the focused `ListView` in
the tree even when no pane rows fit. Command and confirmation take priority over
messages; help, errors, and operation results take priority over browse metadata.
Successful cursor movement clears the message.

## Allocation and lifetime rules

The code uses several allocators with deliberately different lifetimes:

| Storage | Lifetime | Typical contents |
|---|---|---|
| Process/model allocator | Until explicit model or object teardown | Model, panes, messages, previews, identity cache, text field |
| Listing arena | Until that directory snapshot is replaced or transferred away | Entry names and link targets |
| Listing contiguous allocations | Listing lifetime | Entries, selection bits, formatted rows |
| vxfw frame arena | Until the next redraw | Widgets, surfaces, cells, status strings, segments |
| Profiling frame arena | One measured draw, reset with `.free_all` | Headless surfaces and draw temporaries |
| TextField submitted value | Only during the submit callback | Command input |

The central rule is that frame data may borrow durable model data, but durable
state may never retain a pointer into the frame arena. Transactional types use
`errdefer` and explicit source detachment so every allocation has exactly one
owner on both success and rollback paths.

## Performance model

Cursor input plus its requested frame should complete within 16 ms. A changed
HERE cursor always requests that frame directly; it never waits for CHILDREN's
preview timer. Snapshot construction may take longer, but it must not occur for
every cursor event during continuous scrolling.

The design separates those costs:

- directory iteration and sorting happen when a snapshot is built;
- CHILDREN work is debounced during movement;
- visible rows alone are built during layout;
- status counts are cached;
- row clipping stops at pane width;
- transfers reuse snapshots across pane roles;
- rendering performs no filesystem calls.

For `n` ordinary entries, snapshot storage and iteration are linear and sorting
is `O(n log n)`. Restoring `s` selected entries uses expected `O(n + s)` work and
`O(s)` temporary storage, and rewrites only matched display rows. Steady-state
frame work is proportional to viewport height, not directory size.

### Filesystem-specific costs

- **Many ordinary entries:** every name must be copied and sorted, affecting
  startup, watcher refresh, and first preview but not later drawing.
- **Many symbolic links:** every link needs a relative link read and target
  stat; relative operations and snapshot reuse limit the overhead that can be
  avoided.
- **Slow, remote, FUSE, or automounted directories:** an individual synchronous
  open or read can block without a useful upper bound. Debouncing protects
  active scrolling, but the eventual idle load can still pause the event loop.
- **Metadata and NSS:** native stat and account lookup can block. Identity
  caching and debouncing avoid repeating them for intermediate cursor positions.
- **Filesystem event storms:** events are drained and coalesced before one
  transactional refresh.
- **Long names and targets:** snapshot memory scales with byte length, while
  display work stops at the visible cell width.

### Repeatable profiling

The ReleaseSafe profiling executable creates deterministic fixtures under
`.zig-cache/profile`, warms every workload twice, reports minimum, median, and
p95, and removes the fixture afterward:

```sh
zig build profile
zig build profile -- --quick
zig build profile -- --json
zig build profile-check
zig build profile-check -- --json
```

The suite covers 20,000 ordinary files, 2,000 directory-resolving symbolic
links, a 1 MiB text-file fixture, complete model initialization, top and bottom
large-directory frames, cursor movement and pending-preview frames, combined
input plus draw, a watcher refresh with all 20,000 entries selected, and 100 long
links with targets up to 4,000 bytes, capped at the platform path limit. Frame
workloads use production's `.free_all` arena
reset and compose the completed surface tree into a 120×40 cell grid. They do
not emulate Vaxis's final screen diff or a real terminal flush. The preview
itself still obeys the production 128 KiB and 1,024-line bounds. `--samples=N`
changes the frame sample count; scan sample counts are derived from it. Fixture
creation and cleanup are outside the measured regions.

The selected-refresh workload creates and removes a temporary entry, drains the
real watcher, restores the listing and selection, and composes the next frame.
Selection setup is outside measurement; the triggering mutations are included.

Regression gates use these p95 budgets:

| Workload | Budget |
|---|---:|
| Large-directory scan | 50 ms |
| Symlink-heavy scan | 50 ms |
| Text-file preview build | 25 ms |
| Full large-model initialization | 100 ms |
| Selected watcher refresh and frame | 100 ms |
| Cursor movement | 1 ms |
| Every composed frame workload | 4 ms |

The rendering budget deliberately leaves headroom below the 16 ms interaction
target; filesystem budgets are looser to tolerate host and CI variance.

Profile output is the source of current machine-specific measurements; the
checked-in contract is the workload configuration and p95 budget rather than a
timing snapshot that would quickly become stale.

### Remaining latency boundary

Startup, watcher-triggered refresh, hidden-filter changes, deletion refresh,
navigation to a new HERE directory, and the eventual idle preview
remain synchronous. A sufficiently large or slow filesystem can still make
those operations exceed 16 ms.

The next step for a hard bound would be a generation-tagged background loader:
build snapshots away from the UI thread, discard obsolete cursor generations,
and deliver completed ownership through a UI event. That would require explicit
thread allocator, cancellation, watcher-snapshot, and shutdown rules.

vaxis 0.6.0 creates its event loop inside `App.run` and exposes no cross-thread
posting API (`App.Options` carries only `framerate`). Immediate worker wake-up
would require an upstream interface. Safe delivery could instead use an owned,
synchronized result queue polled by the existing timer, with all widget mutation
on the UI thread. That design adds timer latency and needs the ownership,
cancellation, and shutdown rules above; it remains an optional future direction.

## Verification

`zig build test` runs parser, filesystem, watcher, model, headless rendering,
navigation, selection, deletion, timestamp, command-completion, transition,
mixed-input invariant, and allocation-failure coverage. `Model.assertValid`
checks committed pane ownership, row/cursor bounds, anchored paths, projections,
and selection counts throughout integration sequences; the checks are compiled
only into the test and profiling modules (`enable_profile_session`), so shipped
binaries never emit or execute them. `zig build profile-check`
guards the performance budgets above. Tests that draw widgets directly create
and deinitialize their own arenas; multi-frame profile workloads reset theirs
before each frame to mirror vxfw's production lifetime.

The architecture is built around four boundaries:

1. HERE has one model-owned logical cursor. Normal movement crosses
   `applyHereCursor`; full view commits initialize that projection atomically.
2. `Pane.Content` and `PendingPane` make live and staged payload ownership
   explicit.
3. Model-coordinated `PendingView`/`Watcher.Pending` and `PreparedChildren`
   staging provide failure-atomic full and CHILDREN-only replacement.
4. The vxfw frame arena is the lifetime boundary for everything produced by
   drawing.

Keeping those boundaries explicit is what allows pane reuse, live refresh, and
low-cost rendering without stale pointers or partially updated views.
