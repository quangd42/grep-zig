const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;
const ascii = std.ascii;

const Compiler = @import("regex/Compiler.zig");

const Regex = @This();

input: []const u8 = &[_]u8{},
options: Options,
allocator: Allocator,

inst: []Compiler.Inst,
patterns: []Compiler.Pattern,
group_count: usize,

pub fn init(gpa: Allocator, raw: []const u8) !Regex {
    return initWithOptions(gpa, raw, Options{});
}

pub fn initWithOptions(gpa: Allocator, raw: []const u8, options: Options) !Regex {
    var compiler = Compiler.init(gpa, raw);
    defer compiler.deinit();
    try compiler.compile();
    return Regex{
        .options = options,
        .inst = try compiler.inst.toOwnedSlice(),
        .patterns = try compiler.patterns.toOwnedSlice(),
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
    re.group_count = compiler.group_count;
}

pub const Options = struct {
    multiline: bool = false,
    ignore_case: bool = false,
};

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

fn matchPattern(re: *Regex, pattern_idx: u32, char: u8) bool {
    const i = re.options.ignore_case;
    const p = re.patterns[pattern_idx];
    return switch (p) {
        .char => |c| {
            const target = if (i) ascii.toLower(char) else char;
            const pattern = if (i) ascii.toLower(c) else c;
            return pattern == target;
        },
        .range => |r| {
            const target = if (i) ascii.toLower(char) else char;
            const p_from = if (i) ascii.toLower(r.from) else r.from;
            const p_to = if (i) ascii.toLower(r.to) else r.to;
            return p_from <= target and p_to >= target;
        },
        .func => |f| f(char),
    };
}

fn isAtWordBoundary(re: *Regex, input_idx: usize) bool {
    const isAn = Compiler.isAlphanumeric;
    const isWs = Compiler.isWhitespace;

    if (input_idx >= re.input.len) return isAn(re.input[input_idx - 1]);
    const char = re.input[input_idx];

    if (input_idx < 1) return isAn(char);
    const prev = re.input[input_idx - 1];

    return isWs(char) and isAn(prev) or isAn(char) and isWs(prev);
}

fn matchAt(re: *Regex, input_idx: usize, inst_idx: usize, state: *MatchState) !bool {
    if (re.inst.len == 0) return true; // nothing to match
    assert(inst_idx < re.inst.len); // all inst should never point past op.end

    const inst = re.inst[inst_idx];
    return switch (inst.op) {
        .nil => return false,
        .end => return true,
        .split => {
            // Try both paths with cloned states
            var state_copy = try state.clone();
            defer state_copy.deinit();

            return try re.matchAt(input_idx, inst.next, state) or
                try re.matchAt(input_idx, inst.alt, &state_copy);
        },
        .match => |p_idx| {
            if (input_idx >= re.input.len) return false; // not enough input to match pattern
            if (re.matchPattern(p_idx, re.input[input_idx])) {
                return re.matchAt(input_idx + 1, inst.next, state);
            }
            return re.matchAt(input_idx, inst.alt, state);
        },
        .assert => |assertion| {
            switch (assertion) {
                .word_boundary => return if (re.isAtWordBoundary(input_idx)) re.matchAt(input_idx, inst.next, state) else false,
                .non_word_boundary => return if (!re.isAtWordBoundary(input_idx)) re.matchAt(input_idx, inst.next, state) else false,
                .start_line_or_string => {
                    var is_start = false;
                    if (input_idx == 0) {
                        is_start = true;
                    } else if (re.options.multiline and re.input[input_idx - 1] == '\n') {
                        is_start = true;
                    }
                    if (is_start) return re.matchAt(input_idx, inst.next, state) else return false;
                },
                .end_line_or_string => {
                    var is_end = false;
                    if (input_idx >= re.input.len) {
                        is_end = true;
                    } else if (re.options.multiline and re.input[input_idx] == '\n') {
                        is_end = true;
                    }
                    return is_end;
                },
            }
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
            return re.matchAt(input_idx, inst.next, state);
        },
        .backref => |group_num| {
            if (group_num == 0 or group_num > state.items.len) return false;

            const group = &state.items[group_num - 1]; // groups are 1-indexed in regex
            const text = group.getString(re.input) orelse
                // if text == null, group_num refers to a group that was not matched
                return false;
            if (input_idx + text.len > re.input.len) return false;
            if (std.mem.eql(u8, text, re.input[input_idx..][0..text.len])) {
                return re.matchAt(input_idx + text.len, inst.next, state);
            }
            return re.matchAt(input_idx, inst.alt, state);
        },
    };
}

pub fn match(re: *Regex, input: []const u8) !bool {
    re.input = input;

    for (0..input.len) |i| {
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

    const input2 = "\x08\x0D\x0B\x0C\x0A\x1B";
    const raw4 = "\\t\\r\\v\\f\\n\\e";
    try re.compile(raw4);
    try expect(try re.match(input2));

    const raw5 = "\\s+";
    try re.compile(raw5);
    try expect(try re.match(input2));
    try expect(!try re.match("t"));
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
    const multiline1 = "log this\nand other log";
    const multiline2 = "something\nlog some other log\nand done";
    var re = try Regex.initWithOptions(gpa, "^log", .{ .multiline = true });
    defer re.deinit();
    try expect(try re.match(short));
    try expect(!try re.match("LOG"));
    try expect(try re.match(long));
    try expect(try re.match(multiline1));
    try expect(try re.match(multiline2));

    // end of string
    try re.compile("log$");
    try expect(try re.match(short));
    try expect(try re.match(long));
    try expect(try re.match(multiline1));
    try expect(try re.match(multiline2));

    try re.compile("\\bare\\w*\\b");
    try expect(try re.match("area bare arena mare"));

    // non_word_boundary
    try re.compile("\\Bqu\\w+");
    try expect(try re.match("equity queen equip acquaint quiet"));
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

test "options" {
    const gpa = testing.allocator;
    const expect = testing.expect;

    // multiline
    const string = "log this\nand other log";
    const line = "something\nlog some other log\nand done";

    var re = try Regex.initWithOptions(gpa, "^log", .{ .multiline = true });
    defer re.deinit();
    try expect(try re.match(string));
    try expect(try re.match(line));

    try re.compile("log$");
    try expect(try re.match(string));
    try expect(try re.match(line));

    // ignore case
    re.deinit();
    re = try Regex.initWithOptions(gpa, "log \\w+", .{ .ignore_case = true });
    try expect(try re.match("log this"));
    try expect(try re.match("LOG this"));
}
