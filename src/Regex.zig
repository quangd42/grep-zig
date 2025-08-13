const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;

const Compiler = @import("regex/Compiler.zig");

const Regex = @This();

input: []const u8 = &[_]u8{},
allocator: Allocator,

inst: []Compiler.Inst,
patterns: []Compiler.Pattern,
anchors: Compiler.Anchors,
group_count: usize,

pub fn init(gpa: Allocator, raw: []const u8) !Regex {
    var compiler = Compiler.init(gpa, raw);
    defer compiler.deinit();
    try compiler.compile();
    return Regex{
        .inst = try compiler.inst.toOwnedSlice(),
        .patterns = try compiler.patterns.toOwnedSlice(),
        .anchors = compiler.anchors,
        .group_count = compiler.group_count,
        .allocator = gpa,
    };
}

pub fn deinit(re: *Regex) void {
    re.allocator.free(re.inst);
    re.allocator.free(re.patterns);
}

pub fn compile(re: *Regex, raw: []const u8) !void {
    var compiler = Compiler.init(re.allocator, raw);
    defer compiler.deinit();
    try compiler.compile();
    re.deinit();
    re.inst = try compiler.inst.toOwnedSlice();
    re.patterns = try compiler.patterns.toOwnedSlice();
    re.anchors = compiler.anchors;
    re.group_count = compiler.group_count;
}

const Capture = struct {
    start: ?usize = null,
    end: ?usize = null,

    fn getString(self: Capture, input: []const u8) ?[]const u8 {
        const start = self.start orelse return null;
        const end = self.end orelse return null;
        return input[start..end];
    }
};

const MatchState = std.ArrayList(Capture);

fn matchAt(re: *Regex, input_idx: usize, inst_idx: usize, state: *MatchState) !bool {
    if (re.inst.len == 0) return true; // nothing to match
    assert(inst_idx < re.inst.len); // all inst should never point past op.end

    const inst = re.inst[inst_idx];
    return switch (inst.op) {
        .nil => return false,
        .end => {
            if (re.anchors.end and input_idx != re.input.len) return false;
            return true;
        },
        .split => {
            // Try both paths with cloned states
            var state_copy = try state.clone();
            defer state_copy.deinit();

            return try re.matchAt(input_idx, inst.next, state) or
                try re.matchAt(input_idx, inst.alt, &state_copy);
        },
        .match => |p_idx| {
            if (input_idx >= re.input.len) return false; // not enough input to match pattern
            if (re.patterns[p_idx].match(re.input[input_idx])) {
                return try re.matchAt(input_idx + 1, inst.next, state);
            }
            return try re.matchAt(input_idx, inst.alt, state);
        },
        .group_start => |group_num| {
            while (state.items.len <= group_num) {
                state.appendAssumeCapacity(.{});
            }
            state.items[group_num].start = input_idx;
            return try re.matchAt(input_idx, inst.next, state) or try re.matchAt(input_idx, inst.alt, state);
        },
        .group_end => |group_num| {
            assert(group_num < state.items.len);
            state.items[group_num].end = input_idx;
            return try re.matchAt(input_idx, inst.next, state);
        },
        .backref => |group_num| {
            if (group_num == 0 or group_num > state.items.len) return false;

            const group = &state.items[group_num - 1]; // groups are 1-indexed in regex
            const text = group.getString(re.input) orelse
                // if text == null, group_num refers to a group that was not matched
                return false;
            if (input_idx + text.len > re.input.len) return false;
            if (std.mem.eql(u8, text, re.input[input_idx..][0..text.len])) {
                return try re.matchAt(input_idx + text.len, inst.next, state);
            }
            return try re.matchAt(input_idx, inst.alt, state);
        },
    };
}

pub fn match(re: *Regex, input: []const u8) !bool {
    re.input = input;
    const match_range = if (re.anchors.start) 1 else input.len;

    for (0..match_range) |i| {
        var state = try MatchState.initCapacity(re.allocator, re.group_count);
        defer state.deinit();
        if (try re.matchAt(i, 1, &state)) return true;
    }

    return false;
}

fn printInstructions(re: Regex) void {
    for (re.inst, 0..) |inst, i| {
        const print = std.debug.print;
        print("{d:>4} ", .{i});
        switch (inst.op) {
            .match => |p_idx| {
                const pattern = re.patterns[p_idx];
                switch (pattern) {
                    .char => |c| print("char = '{c}'    ", .{c}),
                    .func => |f| print("func = {*}", .{f}),
                    .range => |r| print("match from '{c}' to '{c}' ", .{ r.from, r.to }),
                }
            },
            .nil => print("nil           ", .{}),
            .split => print("split         ", .{}),
            .end => print("end           ", .{}),
            .group_start => |g| print("grp_start = {d:<2}", .{g}),
            .group_end => |g| print("grp_end = {d:<2}  ", .{g}),
            .backref => |g| print("backref = {d:<2}  ", .{g}),
        }
        print(", next = {d:<4}, alt = {d:<4}\n", .{ inst.next, inst.alt });
    }
}

test "match char and escaped char" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const raw = "\\dab";
    const input = "0123abc";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();
    try expect(try re.match(input));

    const raw2 = "\\wbc";
    try re.compile(raw2);
    try expect(try re.match(input));

    const raw3 = "\\";
    try testing.expectError(error.UnexpectedEOF, re.compile(raw3));
}

test "match character group" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const raw3 = "[1a] apple";
    const input3a = "1 apple";
    const input3b = "a apple";
    const input3c = "b apple";

    var re = try Regex.init(gpa, raw3);
    defer re.deinit();
    try expect(try re.match(input3a));
    try expect(try re.match(input3b));
    try expect(!try re.match(input3c));

    const raw4 = "[^1a] apple";
    try re.compile(raw4);
    try expect(try re.match(input3c));
    try expect(!try re.match(input3a));
    try expect(!try re.match(input3b));

    const raw5 = "[x-z] always me";
    try re.compile(raw5);
    try expect(try re.match("y always me"));
    try expect(!try re.match("b always me"));

    const raw6 = "[^x-z] always me";
    try re.compile(raw6);
    try expect(!try re.match("y always me"));
    try expect(try re.match("b always me"));

    const raw7 = "[1-] ball";
    try re.compile(raw7);
    try expect(try re.match("1 ball"));
    try expect(try re.match("- ball"));
    const raw8 = "[-1] ball";
    try re.compile(raw8);
    try expect(try re.match("1 ball"));
    try expect(try re.match("- ball"));

    const raw9 = "[9-1] balls";
    try testing.expectError(error.InvalidCharRange, re.compile(raw9));

    const raw10 = "[abc no close";
    try testing.expectError(error.MissingBracket, re.compile(raw10));
}

test "match anchors" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const long = "logloglog";
    const short = "log";
    const raw5 = "^log";
    var re = try Regex.init(gpa, raw5);
    defer re.deinit();
    try expect(try re.match(short));
    try expect(try re.match(long));

    const raw6 = "log$";
    try re.compile(raw6);
    try expect(try re.match(short));
    try expect(try re.match(long));
}

test "quantifier" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const input1 = "cats";

    const raw = "ca+ts";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();
    try expect(try re.match(input1));
    try expect(try re.match("caats"));
    try expect(try re.match("caaats"));

    const raw2 = "ca?ts";
    try re.compile(raw2);
    try expect(try re.match(input1));
    try expect(try re.match("cts"));

    const raw3 = "ca*ts";
    try re.compile(raw3);
    try expect(try re.match("cts"));
    try expect(try re.match(input1));
    try expect(try re.match("caats"));
    try expect(try re.match("caaats"));
}

test "match wildcard" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const input = "log";
    const raw = "l.g";
    const input1 = "lot";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();
    try expect(try re.match(input));
    try expect(!try re.match(input1));

    const raw2 = ".og";
    try re.compile(raw2);
    try expect(try re.match(input));

    const raw3 = "lo.";
    try re.compile(raw3);
    try expect(try re.match(input));
}

test "match groups with alternation" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const raw = "(abl|cde)+123";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();

    try expect(try re.match("abl123"));
    try expect(try re.match("cde123"));
    try expect(try re.match("ablcde123"));
    try expect(!try re.match("abc123"));
    try expect(!try re.match("xyz123"));

    const raw2 = "x(a|b|c)?y";
    try re.compile(raw2);

    try expect(try re.match("xay"));
    try expect(try re.match("xby"));
    try expect(try re.match("xcy"));
    try expect(try re.match("xy"));
    try expect(!try re.match("xdy"));

    const raw3 = "x(a|b|c?y";
    try testing.expectError(error.MissingParen, re.compile(raw3));
}

test "backreference" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const raw = "(a|b+) \\1";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();

    try expect(try re.match("a a"));
    try expect(try re.match("b b"));
    try expect(try re.match("bbb bbb"));
    try expect(try re.match("bbb bb")); // match is "bb bb"
    try expect(!try re.match("a b"));
    try expect(!try re.match("b a"));

    const raw2 = "(\\d+) (\\w+) squares and \\1 \\2 circles";
    try re.compile(raw2);

    try expect(try re.match("3 red squares and 3 red circles"));
    try expect(!try re.match("3 red squares and 4 red circles"));

    const raw3 = "^I see (\\d (cat|dog|cow)s?(, | and )?)+$";
    try re.compile(raw3);

    try expect(try re.match("I see 1 cat, 2 dogs and 3 cows"));

    const raw4 = "(\\d+ )?(\\w+) squares and \\1\\2 circles";
    try re.compile(raw4);
    try expect(try re.match("3 red squares and 3 red circles"));
    try expect(!try re.match("red squares and red circles"));

    const raw5 = "\\d+ (\\w+) squares and \\1\\2 circles";
    try testing.expectError(error.InvalidBackReference, re.compile(raw5));
}
