//! macOS process policy.

const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        @compileError("the macOS process backend requires aarch64 macOS");
    }
}

pub const open_program = "/usr/bin/open";
