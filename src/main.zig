const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = mem.Allocator;
const testing = std.testing;

const Grep = @import("Grep.zig");
const Regex = @import("Regex.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var g = Grep.init(gpa, args[1..]) catch |err| { // skip the cli name
        switch (err) {
            error.OutOfMemory => return err,
            error.NoPattern => std.debug.print("Usage: grep <flags> [pattern] <files...>\n", .{}),
            error.UnsupportedFlag => std.debug.print("Unsupported flag(s)\n", .{}),
            else => {},
        }
        std.process.exit(1);
    };
    defer g.deinit();

    if (try g.grep()) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}

test "main" {
    @import("std").testing.refAllDeclsRecursive(@This());
}
