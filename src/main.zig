const std = @import("std");
const mem = std.mem;
const testing = std.testing;

fn matchPattern(input_line: []const u8, pattern: []const u8) bool {
    if (pattern.len == 1) {
        return mem.indexOf(u8, input_line, pattern) != null;
    } else if (mem.eql(u8, pattern, "\\d")) {
        for (input_line) |c| {
            if (c >= '0' and c <= '9') return true;
        }
        return false;
    } else {
        @panic("Unhandled pattern");
    }
}

test "002" {
    const pattern = "\\d";
    const input1 = "apple123";
    const input2 = "apple";
    try testing.expect(matchPattern(input1, pattern));
    try testing.expect(!matchPattern(input2, pattern));
}

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !mem.eql(u8, args[1], "-E")) {
        std.debug.print("Expected first argument to be '-E'\n", .{});
        std.process.exit(1);
    }

    const pattern = args[2];
    var input_line: [1024]u8 = undefined;
    const input_len = try std.io.getStdIn().reader().read(&input_line);
    const input_slice = input_line[0..input_len];
    if (matchPattern(input_slice, pattern)) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}
