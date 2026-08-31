//! Small platform policies shared by the model.
//!
//! Filesystem metadata and directory notifications have dedicated modules;
//! this file owns the remaining process-level differences.

const std = @import("std");
const builtin = @import("builtin");

const native = switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    .macos => @import("platform/macos.zig"),
    else => @compileError("Zanger supports only Linux and macOS"),
};

comptime {
    switch (builtin.os.tag) {
        .linux => if (builtin.cpu.arch != .x86_64) {
            @compileError("Zanger supports Linux only on x86_64");
        },
        .macos => if (builtin.cpu.arch != .aarch64) {
            @compileError("Zanger supports macOS only on aarch64");
        },
        else => @compileError("Zanger supports only x86_64 Linux and aarch64 macOS"),
    }
}

/// Native desktop opener. The model still verifies that the target is a
/// non-executable regular file before spawning this program.
pub const open_program = native.open_program;

/// Collects exited opener children without blocking.
pub fn reapChildren() void {
    var status: c_int = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(-1, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                // rc is the child pid, or 0 when children exist but none has
                // exited yet.
                if (rc == 0) return;
            },
            .CHILD => return,
            .INTR => continue,
            else => return,
        }
    }
}
