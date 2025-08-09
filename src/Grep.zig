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

pub fn grepStdin(self: *Grep) !bool {
    var input_line: [1024]u8 = undefined;
    const input_len = try std.io.getStdIn().reader().read(&input_line);
    const input_slice = input_line[0..input_len];

    return self.re.match(input_slice);
}

fn grepFile(self: *Grep, dir: fs.Dir, filepath: []const u8, is_multiple: bool) !bool {
    const file = try dir.openFile(filepath, .{});
    defer file.close();

    const stdout = std.io.getStdOut().writer();
    var matched: usize = 0;
    var buffer: [1024]u8 = undefined;
    while (try file.reader().readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        if (self.re.match(line)) {
            if (is_multiple) {
                _ = try stdout.write(filepath);
                _ = try stdout.write(":");
            }
            _ = try stdout.write(line);
            _ = try stdout.write("\n");
            matched += 1;
        }
    }
    return matched != 0;
}

pub fn grepFiles(self: *Grep, filepaths: [][]const u8) !bool {
    const is_multiple = filepaths.len > 1;
    const cwd = fs.cwd();
    var matched = false;
    for (filepaths) |path| {
        if (try self.grepFile(cwd, path, is_multiple)) matched = true;
    }
    return matched;
}

fn grepDirRecursive(self: *Grep, cwd: fs.Dir, subdir_path: []const u8) !bool {
    var dir = try cwd.openDir(subdir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var matched = false;
    while (try it.next()) |entry| {
        const entry_path = try fs.path.join(self.re.allocator, &[_][]const u8{ subdir_path, entry.name });
        defer self.re.allocator.free(entry_path);
        switch (entry.kind) {
            .file => {
                if (try self.grepFile(cwd, entry_path, true)) matched = true;
            },
            .directory => {
                if (try self.grepDirRecursive(cwd, entry_path)) matched = true;
            },
            else => {},
        }
    }
    return matched;
}

pub fn grepDir(self: *Grep, dirpath: []const u8) !bool {
    const cwd = fs.cwd();
    return self.grepDirRecursive(cwd, dirpath);
}

test "grep files" {
    const gpa = testing.allocator;
    const expect = testing.expect;
    const cwd = fs.cwd();

    var re = try Regex.init(gpa, "appl.*");
    defer re.deinit();
    var g = Grep.init(re);
    try expect(try g.grepFile(cwd, "test/data/fruits.txt", false));

    var re2 = try Regex.init(gpa, "b.+");
    defer re2.deinit();
    var g2 = Grep.init(re2);
    var filepaths: [2][]const u8 = .{ "test/data/fruits.txt", "test/data/vegetables.txt" };
    try expect(try g2.grepFiles(&filepaths));
}

test "grep dir" {
    const gpa = testing.allocator;
    const expect = testing.expect;

    var re = try Regex.init(gpa, "b.+");
    defer re.deinit();
    var g = Grep.init(re);
    try expect(try g.grepDir("test/"));
}
