# Zanger

I like [ranger](https://github.com/ranger/ranger), but it hangs if you happen to
navigate over certain filetypes or large files. This is my 3 pane file
navigator:
- Minimal featureset (no file previews, maybe I'll change my mind at some point)
- Fast

## Build and run

```sh
zig build
zig build run
```

Run all filesystem, parser, and headless UI tests with:

```sh
zig build test
```

Run the repeatable ReleaseSafe performance suite or its regression gate with:

```sh
zig build profile
zig build profile-check
```

The suite uses synthetic large-directory and symlink-heavy fixtures and reports
minimum, median, and p95 timings. Add `-- --quick` for a smaller local run or
`-- --json` for newline-delimited machine-readable results. See
[`ARCHITECTURE.md`](ARCHITECTURE.md) for workloads and budgets.

## Keys

| Key | Action |
|---|---|
| `j` / `k`, arrows | Move in the CWD pane |
| `Ctrl-D` / `Ctrl-U` | Move down / up by half a pane |
| `g` / `G` | Jump to the first / last entry |
| `enter` or `l` | Open a non-empty directory under the CWD cursor |
| `h` or backspace | Move the center to its parent |
| `space` | Toggle selection and move down |
| `Ctrl-H` | Toggle hidden files |
| `:` | Open command mode |
| `q` | Quit |

Left-click and mouse-wheel input are interactive only over the center/CWD pane.
Each wheel action moves one row, including on terminals that emit duplicate
reports. Input over the side panes is ignored.

## Commands

- `:help` — show the key reference.
- `:hidden` — toggle hidden entries.
- `:delete` — confirm deletion of selected entries, or the cursor entry when
  nothing is selected.
- `:quit` — exit.

Commands accept any unambiguous prefix and show the assumed full command in the
status bar while typing. For example, `:d` runs `:delete`; `:h` remains ambiguous
between `:help` and `:hidden`.

Deletion applies only to selected entries in the CWD pane (or its cursor entry
when nothing is selected). Real directories are removed recursively with all
their children. Directory symlinks are unlinked without touching their targets.

The ownership model, event flow, rendering lifecycle, filesystem refresh, and
performance design are documented in [`ARCHITECTURE.md`](ARCHITECTURE.md).
