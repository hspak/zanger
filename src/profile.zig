//! Runs repeatable filesystem and headless rendering performance workloads.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.profile);

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = @import("Model.zig");
const file_system = @import("file_system.zig");

const scan_budget_ns = 50 * std.time.ns_per_ms;
const model_init_budget_ns = 100 * std.time.ns_per_ms;
const frame_budget_ns = 4 * std.time.ns_per_ms;
const text_preview_budget_ns = 25 * std.time.ns_per_ms;
const cursor_budget_ns = 1 * std.time.ns_per_ms;
const warmup_count = 2;

const Options = struct {
    file_count: usize = 20_000,
    symlink_count: usize = 2_000,
    long_symlink_count: usize = 100,
    text_bytes: usize = 1024 * 1024,
    frame_samples: usize = 100,
    scan_samples: usize = 7,
    check: bool = false,
    json: bool = false,
    help: bool = false,
};

const Stats = struct {
    minimum_ns: u64,
    median_ns: u64,
    p95_ns: u64,
};

const Fixture = struct {
    alloc: Allocator,
    io: Io,
    parent: Io.Dir,
    root: Io.Dir,
    sub_path: [sub_path_len]u8,
    path: []u8,
    large_path: []u8,
    symlink_path: []u8,
    long_symlink_path: []u8,
    text_path: []u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init(alloc: Allocator, io: Io, options: Options) !Fixture {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        const parent = try Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/profile", .{});
        errdefer parent.close(io);
        const root = try parent.createDirPathOpen(io, &sub_path, .{});
        errdefer {
            root.close(io);
            parent.deleteTree(io, &sub_path) catch {};
        }

        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        const path = try std.fs.path.join(alloc, &.{
            cwd,
            ".zig-cache",
            "profile",
            &sub_path,
        });
        errdefer alloc.free(path);
        const large_path = try std.fs.path.join(alloc, &.{ path, "large" });
        errdefer alloc.free(large_path);
        const symlink_path = try std.fs.path.join(alloc, &.{ path, "symlinks" });
        errdefer alloc.free(symlink_path);
        const long_symlink_path = try std.fs.path.join(alloc, &.{ path, "long-symlinks" });
        errdefer alloc.free(long_symlink_path);
        const text_path = try std.fs.path.join(alloc, &.{ path, "text" });
        errdefer alloc.free(text_path);

        try populate(alloc, io, root, options);
        return .{
            .alloc = alloc,
            .io = io,
            .parent = parent,
            .root = root,
            .sub_path = sub_path,
            .path = path,
            .large_path = large_path,
            .symlink_path = symlink_path,
            .long_symlink_path = long_symlink_path,
            .text_path = text_path,
        };
    }

    fn deinit(self: *Fixture) void {
        self.root.close(self.io);
        self.parent.deleteTree(self.io, &self.sub_path) catch |err|
            log.warn("failed to remove profiling fixture: {s}", .{@errorName(err)});
        self.parent.close(self.io);
        self.alloc.free(self.text_path);
        self.alloc.free(self.long_symlink_path);
        self.alloc.free(self.symlink_path);
        self.alloc.free(self.large_path);
        self.alloc.free(self.path);
        self.* = undefined;
    }

    fn populate(alloc: Allocator, io: Io, root: Io.Dir, options: Options) !void {
        // One text file whose preview build and frames are measured. Short
        // lines maximize per-line allocation work within the byte budget.
        var text_dir = try root.createDirPathOpen(io, "text", .{});
        defer text_dir.close(io);
        const text_line = "0123456789\n";
        const line_count = options.text_bytes / text_line.len;
        const text_data = try alloc.alloc(u8, line_count * text_line.len);
        defer alloc.free(text_data);
        for (0..line_count) |index| {
            @memcpy(
                text_data[index * text_line.len ..][0..text_line.len],
                text_line,
            );
        }
        try Io.Dir.writeFile(text_dir, io, .{
            .sub_path = "lines.txt",
            .data = text_data,
        });

        var large = try root.createDirPathOpen(io, "large", .{});
        defer large.close(io);
        for (0..options.file_count) |index| {
            var name_buffer: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "file-{d:0>6}", .{index});
            try Io.Dir.writeFile(large, io, .{ .sub_path = name, .data = "" });
        }

        try Io.Dir.createDir(root, io, "target-dir", .default_dir);
        var symlinks = try root.createDirPathOpen(io, "symlinks", .{});
        defer symlinks.close(io);
        for (0..options.symlink_count) |index| {
            var name_buffer: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "link-{d:0>6}", .{index});
            try Io.Dir.symLink(symlinks, io, "../target-dir", name, .{ .is_directory = true });
        }

        var long_symlinks = try root.createDirPathOpen(io, "long-symlinks", .{});
        defer long_symlinks.close(io);
        var long_target: [@min(4000, Io.Dir.max_path_bytes - 1)]u8 = undefined;
        @memset(&long_target, 'x');
        for (0..options.long_symlink_count) |index| {
            var name_buffer: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "long-{d:0>6}", .{index});
            try Io.Dir.symLink(long_symlinks, io, &long_target, name, .{});
        }
    }
};

const DirectoryScan = struct {
    alloc: Allocator,
    io: Io,
    path: []const u8,
    expected_count: usize,

    fn run(self: *DirectoryScan) !void {
        var listing = try file_system.readDir(self.alloc, self.io, self.path, .{});
        defer listing.deinit();
        std.debug.assert(listing.entries.len == self.expected_count);
        std.mem.doNotOptimizeAway(listing.rows.ptr);
    }
};

const ModelInit = struct {
    alloc: Allocator,
    io: Io,
    path: []const u8,
    expected_count: usize,

    fn run(self: *ModelInit) !void {
        var session = try Model.ProfileSession.init(self.alloc, self.io, self.path);
        defer session.deinit();
        std.debug.assert(session.entryCount() == self.expected_count);
        std.mem.doNotOptimizeAway(session.entryCount());
    }
};

const DrawFrame = struct {
    session: *Model.ProfileSession,
    arena: *std.heap.ArenaAllocator,

    fn run(self: *DrawFrame) !void {
        _ = self.arena.reset(.retain_capacity);
        const surface = try self.session.draw(drawContext(self.arena.allocator()));
        std.mem.doNotOptimizeAway(surface.children.len);
    }
};

const MoveCursor = struct {
    session: *Model.ProfileSession,
    event_ctx: *vxfw.EventContext,
    down: bool = true,

    fn run(self: *MoveCursor) !void {
        self.event_ctx.consume_event = false;
        self.event_ctx.redraw = false;
        try self.session.moveCursor(self.event_ctx, self.down);
        self.down = !self.down;
    }
};

const CursorFrame = struct {
    cursor: *MoveCursor,
    frame: *DrawFrame,

    fn run(self: *CursorFrame) !void {
        try self.cursor.run();
        try self.frame.run();
    }
};

fn drawContext(arena: Allocator) vxfw.DrawContext {
    return .{
        .arena = arena,
        .min = .{ .width = 120, .height = 40 },
        .max = .{ .width = 120, .height = 40 },
        .cell_size = .{ .width = 8, .height = 16 },
    };
}

fn measure(
    alloc: Allocator,
    io: Io,
    sample_count: usize,
    operation: anytype,
) !Stats {
    std.debug.assert(sample_count > 0);
    for (0..warmup_count) |_| try operation.run();

    const samples = try alloc.alloc(u64, sample_count);
    defer alloc.free(samples);
    for (samples) |*sample| {
        const started = Io.Clock.awake.now(io).nanoseconds;
        try operation.run();
        const finished = Io.Clock.awake.now(io).nanoseconds;
        std.debug.assert(finished >= started);
        sample.* = @intCast(finished - started);
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const p95_index = @min((sample_count * 95 + 99) / 100 - 1, sample_count - 1);
    return .{
        .minimum_ns = samples[0],
        .median_ns = samples[sample_count / 2],
        .p95_ns = samples[p95_index],
    };
}

fn emitMetric(
    writer: *Io.Writer,
    options: Options,
    name: []const u8,
    stats: Stats,
    budget_ns: ?u64,
) !bool {
    const passed = if (budget_ns) |budget| stats.p95_ns <= budget else true;
    if (options.json) {
        if (budget_ns) |budget| {
            try writer.print(
                "{{\"kind\":\"metric\",\"name\":\"{s}\",\"minimum_ns\":{d}," ++
                    "\"median_ns\":{d},\"p95_ns\":{d},\"budget_ns\":{d}," ++
                    "\"passed\":{}}}\n",
                .{ name, stats.minimum_ns, stats.median_ns, stats.p95_ns, budget, passed },
            );
        } else {
            try writer.print(
                "{{\"kind\":\"metric\",\"name\":\"{s}\",\"minimum_ns\":{d}," ++
                    "\"median_ns\":{d},\"p95_ns\":{d},\"budget_ns\":null," ++
                    "\"passed\":true}}\n",
                .{ name, stats.minimum_ns, stats.median_ns, stats.p95_ns },
            );
        }
        return passed;
    }

    const minimum_ms = @as(f64, @floatFromInt(stats.minimum_ns)) / std.time.ns_per_ms;
    const median_ms = @as(f64, @floatFromInt(stats.median_ns)) / std.time.ns_per_ms;
    const p95_ms = @as(f64, @floatFromInt(stats.p95_ns)) / std.time.ns_per_ms;
    if (budget_ns) |budget| {
        const budget_ms = @as(f64, @floatFromInt(budget)) / std.time.ns_per_ms;
        try writer.print(
            "{s}: min={d:.4} ms median={d:.4} ms p95={d:.4} ms " ++
                "budget={d:.4} ms {s}\n",
            .{ name, minimum_ms, median_ms, p95_ms, budget_ms, if (passed) "PASS" else "FAIL" },
        );
    } else {
        try writer.print(
            "{s}: min={d:.4} ms median={d:.4} ms p95={d:.4} ms\n",
            .{ name, minimum_ms, median_ms, p95_ms },
        );
    }
    return passed;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var quick = false;
    var sample_override: ?usize = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            quick = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.startsWith(u8, arg, "--samples=")) {
            sample_override = try std.fmt.parseUnsigned(
                usize,
                arg["--samples=".len..],
                10,
            );
            if (sample_override.? == 0 or sample_override.? > 10_000) {
                return error.InvalidArguments;
            }
        } else {
            return error.InvalidArguments;
        }
    }
    if (quick) {
        options.file_count = 2_000;
        options.symlink_count = 200;
        options.long_symlink_count = 20;
        options.text_bytes = 128 * 1024;
        options.frame_samples = 25;
        options.scan_samples = 3;
    }
    if (sample_override) |samples| {
        options.frame_samples = samples;
        options.scan_samples = @max(1, samples / 10);
    }
    return options;
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\usage: zanger-profile [--check] [--json] [--quick] [--samples=N] [--help]
        \\
        \\  --check       exit unsuccessfully when a workload p95 exceeds its budget
        \\  --json        emit newline-delimited JSON
        \\  --quick       use smaller fixtures and fewer samples
        \\  --samples=N   override the number of frame samples
        \\  --help        show this help
        \\
    );
}

fn runSuite(
    alloc: Allocator,
    io: Io,
    writer: *Io.Writer,
    options: Options,
) !bool {
    if (options.json) {
        try writer.print(
            "{{\"kind\":\"config\",\"mode\":\"ReleaseSafe\",\"width\":120," ++
                "\"height\":40,\"files\":{d},\"symlinks\":{d}," ++
                "\"long_symlinks\":{d},\"text_bytes\":{d}," ++
                "\"frame_samples\":{d},\"scan_samples\":{d}}}\n",
            .{
                options.file_count,
                options.symlink_count,
                options.long_symlink_count,
                options.text_bytes,
                options.frame_samples,
                options.scan_samples,
            },
        );
    } else {
        try writer.print(
            "zanger profile: ReleaseSafe, 120x40, {d} files, {d} directory symlinks, " ++
                "{d} long symlinks, {d} KiB text\n",
            .{
                options.file_count,
                options.symlink_count,
                options.long_symlink_count,
                options.text_bytes / 1024,
            },
        );
    }
    try writer.flush();

    var fixture = try Fixture.init(alloc, io, options);
    defer fixture.deinit();
    var passed = true;

    var large_scan: DirectoryScan = .{
        .alloc = alloc,
        .io = io,
        .path = fixture.large_path,
        .expected_count = options.file_count,
    };
    passed = try emitMetric(
        writer,
        options,
        "large_directory_scan",
        try measure(alloc, io, options.scan_samples, &large_scan),
        scan_budget_ns,
    ) and passed;

    var symlink_scan: DirectoryScan = .{
        .alloc = alloc,
        .io = io,
        .path = fixture.symlink_path,
        .expected_count = options.symlink_count,
    };
    passed = try emitMetric(
        writer,
        options,
        "symlink_directory_scan",
        try measure(alloc, io, options.scan_samples, &symlink_scan),
        scan_budget_ns,
    ) and passed;

    var model_init: ModelInit = .{
        .alloc = alloc,
        .io = io,
        .path = fixture.large_path,
        .expected_count = options.file_count,
    };
    passed = try emitMetric(
        writer,
        options,
        "large_model_init",
        try measure(alloc, io, options.scan_samples, &model_init),
        model_init_budget_ns,
    ) and passed;

    vxfw.DrawContext.init(.unicode);
    var session = try Model.ProfileSession.init(alloc, io, fixture.large_path);
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var event_ctx: vxfw.EventContext = .{
        .io = io,
        .alloc = alloc,
        .cmds = .empty,
        .redraw = false,
    };
    defer event_ctx.cmds.deinit(alloc);
    var frame: DrawFrame = .{ .session = &session, .arena = &arena };

    passed = try emitMetric(
        writer,
        options,
        "large_top_frame",
        try measure(alloc, io, options.frame_samples, &frame),
        frame_budget_ns,
    ) and passed;

    try session.jumpCursor(&event_ctx, true);
    try session.syncPreview();
    passed = try emitMetric(
        writer,
        options,
        "large_bottom_frame",
        try measure(alloc, io, options.frame_samples, &frame),
        frame_budget_ns,
    ) and passed;

    try session.jumpCursor(&event_ctx, false);
    try session.syncPreview();
    var cursor: MoveCursor = .{ .session = &session, .event_ctx = &event_ctx };
    passed = try emitMetric(
        writer,
        options,
        "cursor_move",
        try measure(alloc, io, options.frame_samples, &cursor),
        cursor_budget_ns,
    ) and passed;
    passed = try emitMetric(
        writer,
        options,
        "cursor_pending_frame",
        try measure(alloc, io, options.frame_samples, &frame),
        frame_budget_ns,
    ) and passed;

    var cursor_frame: CursorFrame = .{ .cursor = &cursor, .frame = &frame };
    passed = try emitMetric(
        writer,
        options,
        "cursor_input_and_frame",
        try measure(alloc, io, options.frame_samples, &cursor_frame),
        frame_budget_ns,
    ) and passed;

    var long_session = try Model.ProfileSession.init(alloc, io, fixture.long_symlink_path);
    defer long_session.deinit();
    var long_frame: DrawFrame = .{ .session = &long_session, .arena = &arena };
    passed = try emitMetric(
        writer,
        options,
        "long_symlink_frame",
        try measure(alloc, io, options.frame_samples, &long_frame),
        frame_budget_ns,
    ) and passed;

    // Building the preview reads and splits every line of the fixture file.
    var text_init: ModelInit = .{
        .alloc = alloc,
        .io = io,
        .path = fixture.text_path,
        .expected_count = 1,
    };
    passed = try emitMetric(
        writer,
        options,
        "text_preview_build",
        try measure(alloc, io, options.scan_samples, &text_init),
        text_preview_budget_ns,
    ) and passed;

    var text_session = try Model.ProfileSession.init(alloc, io, fixture.text_path);
    defer text_session.deinit();
    var text_frame: DrawFrame = .{ .session = &text_session, .arena = &arena };
    passed = try emitMetric(
        writer,
        options,
        "text_preview_top_frame",
        try measure(alloc, io, options.frame_samples, &text_frame),
        frame_budget_ns,
    ) and passed;

    return passed;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const options = parseOptions(args) catch |err| {
        try stdout.print("invalid arguments: {s}\n\n", .{@errorName(err)});
        try usage(stdout);
        try stdout.flush();
        std.process.exit(2);
    };
    if (options.help) {
        try usage(stdout);
        try stdout.flush();
        return;
    }
    const passed = try runSuite(alloc, io, stdout, options);
    try stdout.flush();
    if (options.check and !passed) std.process.exit(1);
}
