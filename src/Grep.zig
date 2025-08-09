const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const testing = std.testing;
const Allocator = mem.Allocator;

const Regex = @import("Regex.zig");

const Grep = @This();

re: Regex,

pub fn init(re: Regex) Grep {
    return .{
        .re = re,
    };
}

pub fn grepFile(self: *Grep, dir: fs.Dir, filepath: []const u8) !bool {
    const file = try dir.openFile(filepath, .{});
    defer file.close();

    const stdout = std.io.getStdOut().writer();
    var matched: usize = 0;
    var buffer: [1024]u8 = undefined;
    while (try file.reader().readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        if (self.re.match(line)) {
            _ = try stdout.write(line);
            _ = try stdout.write("\n");
            matched += 1;
        }
    }
    return matched != 0;
}

fn grepDirRecursive(self: *Grep, dir: fs.Dir, subdir_path: []const u8) !bool {
    var subdir = try dir.openDir(subdir_path, .{ .iterate = true });
    defer subdir.close();
    var it = subdir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => return self.grepFile(subdir, entry.name),
            .directory => return self.grepDirRecursive(subdir, entry.name),
            else => return false,
        }
    }
    return false;
}

fn grepDir(self: *Grep, dirpath: []const u8) !bool {
    var dir = try fs.cwd().openDir(dirpath, .{ .iterate = true });
    defer dir.close();
    return self.grepDirRecursive(dir, ".");
}

test "grep" {
    const gpa = testing.allocator;
    var re = try Regex.init(gpa, "appl.*");
    defer re.deinit();
    var g = Grep.init(re);
    const dir = fs.cwd();
    try testing.expect(try g.grepFile(dir, "test/data/fruits.txt"));
}
