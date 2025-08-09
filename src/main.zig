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

    if (args.len < 3 or !mem.eql(u8, args[1], "-E")) {
        std.debug.print("Expected first argument to be '-E'\n", .{});
        std.process.exit(1);
    }

    const pattern = args[2];
    var matched = false;
    var re = try Regex.init(gpa, pattern);
    defer re.deinit();

    if (args.len == 3) {
        var input_line: [1024]u8 = undefined;
        const input_len = try std.io.getStdIn().reader().read(&input_line);
        const input_slice = input_line[0..input_len];

        matched = re.match(input_slice);
    } else {
        const path = args[3];
        var grep = Grep.init(re);
        const dir = fs.cwd();
        matched = try grep.grepFile(dir, path);
    }

    if (matched) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}

test "main" {
    @import("std").testing.refAllDeclsRecursive(@This());
}
