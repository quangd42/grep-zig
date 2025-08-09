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

    if (try run(gpa, args)) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}

fn run(gpa: Allocator, args: [][:0]u8) !bool {
    if (args.len < 3) {
        std.debug.print("Expected first argument to be '-E'\n", .{});
        std.process.exit(1);
    }

    const recursive = mem.eql(u8, args[1], "-r");
    var matched = false;
    if (recursive) {
        if (!mem.eql(u8, args[2], "-E")) {
            std.debug.print("Expected second argument to be '-E'\n", .{});
            std.process.exit(1);
        }
        const pattern = args[3];
        var re = try Regex.init(gpa, pattern);
        defer re.deinit();
        const path = args[4];
        var grep = Grep.init(re);
        matched = try grep.grepDir(path);
    } else if (mem.eql(u8, args[1], "-E")) {
        const pattern = args[2];
        var re = try Regex.init(gpa, pattern);
        defer re.deinit();
        var grep = Grep.init(re);
        const filepaths = args[3..];
        if (filepaths.len == 0) {
            matched = try grep.grepStdin();
        } else {
            matched = try grep.grepFiles(filepaths);
        }
    } else {
        std.debug.print("Expected first argument to be '-E'\n", .{});
        std.process.exit(1);
    }

    return matched;
}

test "main" {
    @import("std").testing.refAllDeclsRecursive(@This());
}
