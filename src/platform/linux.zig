//! Linux process policy.

const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        @compileError("the Linux process backend requires x86_64 Linux");
    }
}

pub const open_program = "xdg-open";
