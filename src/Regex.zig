const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const testing = std.testing;
const assert = std.debug.assert;

const Regex = @This();

pub const Inst = struct {
    /// match the patterns at idx..idx+len
    op: Op,
    next: usize,
    alt: usize = 0,

    const Op = union(enum) {
        match: CharMatcher,
        nil,
        end,
        split,
        // group number of the capture text
        group_start: usize,
        group_end: usize,
        // group number to reference
        backref: usize,
    };

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self.op) {
            .match => |m| {
                switch (m) {
                    .char => |c| try writer.print("char = '{c}'    ", .{c}),
                    .func => |f| try writer.print("func = {*}", .{f}),
                    .range => |r| try writer.print("match from '{c}' to '{c}' ", .{ r.from, r.to }),
                }
            },
            .nil => try writer.print("nil           ", .{}),
            .split => try writer.print("split         ", .{}),
            .end => try writer.print("end           ", .{}),
            .group_start => |g| try writer.print("grp_start = {d:<2}", .{g}),
            .group_end => |g| try writer.print("grp_end = {d:<2}  ", .{g}),
            .backref => |g| try writer.print("backref = {d:<2}  ", .{g}),
        }
        try writer.print(", next = {d:<4}, alt = {d:<4}", .{ self.next, self.alt });
    }
};

const Anchors = struct {
    start: bool,
    end: bool,
};

raw: []const u8,
input: []const u8 = &[_]u8{},
allocator: Allocator,

cursor: usize = 0,
inst: std.ArrayList(Inst),
anchors: Anchors,
group_count: usize = 0,

const Error = error{ OutOfMemory, UnexpectedEOF, UnsupportedClass, InvalidBackReference, InvalidCharRange };

pub fn init(gpa: Allocator, raw: []const u8) !Regex {
    var out = Regex{
        .raw = raw,
        .inst = .init(gpa),
        .anchors = .{ .start = false, .end = false },
        .allocator = gpa,
    };
    try out._compile();
    return out;
}

pub fn deinit(re: *Regex) void {
    re.inst.deinit();
}

fn _compile(re: *Regex) !void {
    // reserving first inst as nil
    try re.inst.append(.{ .op = .nil, .next = 0 });
    if (re.raw[re.cursor] == '^') {
        re.anchors.start = true;
        re.cursor += 1;
    }

    try re.parseAlternation();

    try re.inst.append(.{ .op = .end, .next = 0 });
}

pub fn compile(re: *Regex, raw: []const u8) !void {
    const new = try Regex.init(re.allocator, raw);
    re.deinit();
    re.* = new;
}

inline fn peek(re: *Regex) u8 {
    return re.raw[re.cursor];
}

inline fn next(re: *Regex) void {
    re.cursor += 1;
}

inline fn split(re: *Regex, next_idx: usize, alt_idx: usize) !void {
    try re.inst.append(.{
        .op = .split,
        .next = next_idx,
        .alt = alt_idx,
    });
}

inline fn matchChar(re: *Regex, m: CharMatcher, next_idx: usize, alt_idx: usize) !void {
    return re.inst.append(.{
        .op = .{ .match = m },
        .next = next_idx,
        .alt = alt_idx,
    });
}

fn backref(re: *Regex) !Inst {
    const num_start = re.cursor;
    while (re.cursor < re.raw.len and isDigit(re.peek())) : (re.cursor += 1) {}
    const num = std.fmt.parseInt(usize, re.raw[num_start..re.cursor], 10) catch
        return error.InvalidBackReference;

    // to account for the automatic next() at the end of parseAtom()
    re.cursor -= 1;

    return .{ .op = .{ .backref = num }, .next = re.inst.items.len + 1 };
}

fn escapedChar(re: *Regex) !void {
    if (re.cursor + 1 >= re.raw.len) return error.UnexpectedEOF;
    re.next();
    const next_inst = re.inst.items.len + 1;
    try re.inst.append(switch (re.peek()) {
        'd' => .{ .op = .{ .match = .{ .func = &isDigit } }, .next = next_inst },
        'w' => .{ .op = .{ .match = .{ .func = &isAlphanumeric } }, .next = next_inst },
        '-' => |c| .{ .op = .{ .match = .{ .char = c } }, .next = next_inst },
        '1'...'9' => try re.backref(),
        else => return error.UnexpectedEOF,
    });
}

fn charGroup(re: *Regex) !void {
    re.next(); // '['
    if (re.cursor >= re.raw.len) return error.UnexpectedEOF;
    const negated = re.peek() == '^';
    if (negated) re.next(); // '^'

    try re.split(re.inst.items.len + 1, 0);
    const start = re.inst.items.len;

    while (re.raw[re.cursor] != ']') {
        if (re.cursor >= re.raw.len) return error.UnexpectedEOF;
        try re.parseAtom(true);
    }
    const group_next = re.inst.items.len;
    var i = start;
    if (!negated) {
        // patch each inst
        while (i < group_next) : (i += 1) {
            re.inst.items[i].next = group_next;
            re.inst.items[i].alt = i + 1;
        }
        // for last inst of group, no more alt
        re.inst.items[group_next - 1].alt = 0;
    } else {
        while (i < group_next) : (i += 1) {
            // if matched inst should return false
            re.inst.items[i].next = 0;
            // if not matched (aka alt) try again with next inst
            re.inst.items[i].alt = i + 1;
        }
        // at last inst, if not matched then none of the negative patterns matched
        // add inst to consume current input char (which last inst is pointing to)
        try re.inst.append(.{
            .op = .{ .match = .{ .func = &isAny } },
            .next = group_next + 1,
            .alt = 0,
        });
    }
}

fn charRange(re: *Regex) !void {
    if (re.cursor + 1 >= re.raw.len) return error.UnexpectedEOF;
    const to = re.raw[re.cursor + 1];
    const prev = re.raw[re.cursor - 1];

    // '-' is matched literally
    if (prev == '[' or
        (prev == '^' and re.raw[re.cursor - 2] == '[') or // safe because in_char_group == true
        to == ']')
        return re.matchChar(.{ .char = re.peek() }, re.inst.items.len + 1, 0);

    re.next(); // consume the 'to' char
    const from_inst = &re.inst.items[re.inst.items.len - 1];
    const from: u8 = blk: switch (from_inst.op) {
        .match => |m| switch (m) {
            .char => |c| break :blk c,
            else => return error.InvalidCharRange,
        },
        else => return error.InvalidCharRange,
    };

    if (from > to) return error.InvalidCharRange;

    from_inst.op = .{ .match = .{ .range = .{ .from = from, .to = to } } };
}

const CharMatcher = union(enum) {
    char: u8,
    range: Range,
    func: *const fn (u8) bool,

    const Range = struct {
        from: u8,
        to: u8,
    };

    fn match(s: CharMatcher, char: u8) bool {
        return switch (s) {
            .char => |c| char == c,
            .range => |r| r.from <= char and r.to >= char,
            .func => |f| f(char),
        };
    }
};

fn isDigit(c: u8) bool {
    return ascii.isDigit(c);
}

fn isAlphanumeric(c: u8) bool {
    return c == '_' or ascii.isAlphanumeric(c);
}

fn isAny(_: u8) bool {
    return true;
}

fn parseAtom(re: *Regex, in_char_group: bool) Error!void {
    if (re.cursor >= re.raw.len) return;
    defer re.next();

    switch (re.peek()) {
        '\\' => try re.escapedChar(),
        '[' => try re.charGroup(),
        '.' => {
            try re.inst.append(.{
                .op = .{ .match = .{ .func = &isAny } },
                .next = re.inst.items.len + 1,
            });
        },
        '$' => {
            if (re.cursor == re.raw.len - 1) {
                re.anchors.end = true;
            } else return error.UnsupportedClass;
        },
        '(' => {
            re.next(); // '('
            const group_num = re.group_count;
            re.group_count += 1;

            try re.inst.append(.{
                .op = .{ .group_start = group_num },
                .next = re.inst.items.len + 1,
            });
            try re.parseAlternation();
            try re.inst.append(.{
                .op = .{ .group_end = group_num },
                .next = re.inst.items.len + 1,
            });
        },
        '-' => {
            if (!in_char_group)
                return re.matchChar(.{ .char = re.peek() }, re.inst.items.len + 1, 0);

            try re.charRange();
        },
        else => try re.inst.append(.{
            .op = .{ .match = .{ .char = re.peek() } },
            .next = re.inst.items.len + 1,
        }),
    }
}

fn parseRepetition(re: *Regex) !void {
    const start_idx = re.inst.items.len;
    try re.parseAtom(false);

    if (re.cursor >= re.raw.len) return;
    switch (re.peek()) {
        '+' => {
            try re.split(start_idx, re.inst.items.len + 1);
            re.next();
        },
        '?' => {
            // char group and capture group both have a "start group" inst
            re.inst.items[start_idx].alt = re.inst.items.len;
            re.next();
        },
        '*' => {
            // char group and capture group both have a "start group" inst
            re.inst.items[start_idx].alt = re.inst.items.len + 1;
            try re.split(start_idx, re.inst.items.len + 1);
            re.next();
        },
        else => return,
    }
}

fn parseConcat(re: *Regex) !void {
    while (re.cursor < re.raw.len) {
        if (re.peek() == '|' or re.peek() == ')') return;
        try re.parseRepetition();
    }
}

fn parseAlternation(re: *Regex) !void {
    const split_idx = re.inst.items.len;
    try re.split(split_idx + 1, 0); // alt to be patched
    try re.parseConcat();
    if (re.cursor < re.raw.len and re.peek() == '|') {
        re.inst.items[split_idx].alt = re.inst.items.len;
        re.next();
        const last_alt = re.inst.items.len - 1;
        try re.parseAlternation();
        re.inst.items[last_alt].next = re.inst.items.len;
    }
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
    if (re.inst.items.len == 0) return true; // nothing to match
    assert(inst_idx < re.inst.items.len); // all inst should never point past op.end

    const inst = re.inst.items[inst_idx];
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
        .match => |char_matcher| {
            if (input_idx >= re.input.len) return false; // not enough input to match pattern
            if (char_matcher.match(re.input[input_idx])) {
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
    for (re.inst.items, 0..) |in, i| {
        std.debug.print("{d:>4} {}\n", .{ i, in });
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
}
