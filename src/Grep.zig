const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const testing = std.testing;
const Allocator = mem.Allocator;

const Regex = @import("Regex.zig");

const Grep = @This();

re: Regex,
options: Options,

pub fn init(gpa: Allocator, args: [][:0]u8) !Grep {
    var options = Options{};
    const slices = try gpa.alloc([]const u8, args.len);
    defer gpa.free(slices);
    for (args, 0..) |arg, i| {
        slices[i] = std.mem.span(arg.ptr);
    }
    try options.parseArgs(gpa, slices);
    if (options.pattern == null or options.pattern.?.len == 0) return error.NoPattern;
    const re = try Regex.init(gpa, options.pattern.?);
    return .{
        .re = re,
        .options = options,
    };
}

pub fn deinit(self: *Grep) void {
    self.re.deinit();
    self.options.deinit(self.re.allocator);
}

pub fn grep(self: *Grep) !bool {
    if (!self.options.extended_regex) {
        // hardcode for the challenge
        std.debug.print("Expected first argument to be '-E'\n", .{});
        return false;
    }
    if (self.options.recursive) {
        if (self.options.paths == null or self.options.paths.?.len == 0) {
            return error.TargetRequired;
        }
        return self.grepDir(self.options.paths.?[0]);
    } else if (self.options.paths == null or self.options.paths.?.len == 0) {
        return self.grepStdin();
    } else {
        return self.grepFiles(self.options.paths.?);
    }
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
    var g = Grep{ .re = re, .options = Options{} };
    try expect(try g.grepFile(cwd, "test/data/fruits.txt", false));

    var re2 = try Regex.init(gpa, "b.+");
    defer re2.deinit();
    var g2 = Grep{ .re = re2, .options = Options{} };
    var filepaths: [2][]const u8 = .{ "test/data/fruits.txt", "test/data/vegetables.txt" };
    try expect(try g2.grepFiles(&filepaths));
}

test "grep dir" {
    const gpa = testing.allocator;
    const expect = testing.expect;

    var re = try Regex.init(gpa, "b.+");
    defer re.deinit();
    var g = Grep{ .re = re, .options = Options{} };
    try expect(try g.grepDir("test/"));
}

const Options = struct {
    extended_regex: bool = false,
    recursive: bool = false,
    pattern: ?[]const u8 = null,
    paths: ?[][]const u8 = null,

    fn deinit(self: *Options, gpa: Allocator) void {
        if (self.pattern) |pattern| gpa.free(pattern);
        if (self.paths) |paths| gpa.free(paths);
    }

    fn parseArgs(self: *Options, gpa: Allocator, args: [][]const u8) !void {
        if (args.len == 0) {
            // hardcode for the challenge
            std.debug.print("Expected first argument to be '-E'\n", .{});
            return;
        }

        var arg_idx: usize = 0;
        while (arg_idx < args.len) : (arg_idx += 1) {
            const arg = args[arg_idx];
            switch (arg[0]) {
                '-' => try self.parseShort(arg[1..]),
                else => {
                    self.pattern = try gpa.dupe(u8, arg);
                    self.paths = try gpa.dupe([]const u8, args[arg_idx + 1 ..]);
                    break;
                },
            }
        }
    }

    fn parseShort(self: *Options, arg: []const u8) !void {
        if (arg.len == 0) return;
        switch (arg[0]) {
            '-' => try self.parseLong(arg[1..]),
            else => {
                for (arg) |c| {
                    switch (c) {
                        'E' => self.extended_regex = true,
                        'r' => self.recursive = true,
                        else => return error.UnsupportedFlag,
                    }
                }
            },
        }
    }

    fn parseLong(self: *Options, arg: []const u8) !void {
        if (arg.len == 0) return;
        if (mem.eql(u8, arg, "extended-regexp")) {
            self.extended_regex = true;
        } else if (mem.eql(u8, arg, "recursive")) {
            self.recursive = true;
        } else {
            return error.UnsupportedFlag;
        }
    }
};

fn constCastArgs(gpa: Allocator, from: [][:0]const u8) ![][:0]u8 {
    const to = try gpa.alloc([:0]u8, from.len);
    for (from, 0..) |a, i| {
        to[i] = @constCast(a);
    }
    return to;
}

test "parse args" {
    const gpa = testing.allocator;
    const expect = testing.expect;
    const expectEqualStrings = testing.expectEqualStrings;

    const pattern = "b.+";
    const path1 = "fruits.txt";
    var raw_args = [_][:0]const u8{ "-r", "-E", pattern, path1 };
    const args = try constCastArgs(gpa, &raw_args);
    defer gpa.free(args);
    var g = try Grep.init(gpa, args);
    defer g.deinit();
    try expect(g.options.extended_regex);
    try expect(g.options.recursive);
    try expectEqualStrings(pattern[0..], g.options.pattern.?);
    try expect(g.options.paths.?.len == 1);
    try expectEqualStrings(path1[0..], g.options.paths.?[0]);

    const path2 = "vegetables.txt";
    var raw_args2 = [_][:0]const u8{ "-rE", pattern, path1, path2 };
    const args2 = try constCastArgs(gpa, &raw_args2);
    var g2 = try Grep.init(gpa, args2);
    defer gpa.free(args2);
    defer g2.deinit();
    try expect(g2.options.extended_regex);
    try expect(g2.options.recursive);
    try expectEqualStrings(pattern[0..], g2.options.pattern.?);
    try expect(g2.options.paths.?.len == 2);
    try expectEqualStrings(path1[0..], g2.options.paths.?[0]);
    try expectEqualStrings(path2[0..], g2.options.paths.?[1]);

    var raw_noflag = [_][:0]const u8{ pattern, path1, path2 };
    const noflag = try constCastArgs(gpa, &raw_noflag);
    var g3 = try Grep.init(gpa, noflag);
    defer gpa.free(noflag);
    defer g3.deinit();
    try expect(!g3.options.extended_regex);
    try expect(!g3.options.recursive);
    try expectEqualStrings(pattern[0..], g3.options.pattern.?);
    try expect(g3.options.paths.?.len == 2);
    try expectEqualStrings(path1[0..], g3.options.paths.?[0]);
    try expectEqualStrings(path2[0..], g3.options.paths.?[1]);

    // test no paths
    var raw_nopath = [_][:0]const u8{ "-r", pattern };
    const nopath = try constCastArgs(gpa, &raw_nopath);
    defer gpa.free(nopath);
    var g4 = try Grep.init(gpa, nopath);
    defer g4.deinit();
    try expect(!g4.options.extended_regex);
    try expect(g4.options.recursive);
    try expectEqualStrings(pattern[0..], g4.options.pattern.?);
    try expect(g4.options.paths.?.len == 0);

    // test no pattern
    var raw_nopattern = [_][:0]const u8{"-E"};
    const nopattern = try constCastArgs(gpa, &raw_nopattern);
    defer gpa.free(nopattern);
    try testing.expectError(error.NoPattern, Grep.init(gpa, nopattern));
}
