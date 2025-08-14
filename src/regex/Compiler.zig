const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const cc = ascii.control_code;

const Compiler = @This();

const Error = error{
    OutOfMemory,
    UnexpectedEOF,
    UnsupportedClass,
    InvalidBackReference,
    InvalidCharRange,
    MissingRepeatArgument,
    MissingBracket,
    MissingParen,
};

raw: []const u8,
inst: std.ArrayList(Inst),
patterns: std.ArrayList(Pattern),
cursor: u32 = 0,
group_count: u32 = 0,

pub fn init(gpa: Allocator, raw: []const u8) Compiler {
    return .{
        .raw = raw,
        .inst = .init(gpa),
        .patterns = .init(gpa),
    };
}

pub fn deinit(c: *Compiler) void {
    c.inst.deinit();
    c.patterns.deinit();
}

pub fn compile(c: *Compiler) !void {
    // reserving first inst as nil
    try c.inst.append(.{ .op = .nil, .next = 0 });

    try c.compileAlternation();

    try c.inst.append(.{ .op = .end, .next = 0 });
}

fn compileAtom(c: *Compiler, in_char_group: bool) Error!void {
    if (c.cursor >= c.raw.len) return;

    switch (c.peek()) {
        '\\' => try c.escapedChar(),
        '[' => try c.charGroup(),
        '.' => {
            try c.instMatch(.{ .func = &isAny }, c.inst.items.len + 1, 0);
            c.next();
        },
        '(' => try c.captureGroup(),
        '-' => {
            if (!in_char_group) {
                try c.instMatch(.{ .char = c.peek() }, c.inst.items.len + 1, 0);
                return c.next();
            }

            try c.charRange();
        },
        '^' => {
            if (c.cursor == 0) {
                try c.instAssert(.start_line_or_string);
            } else return error.UnsupportedClass;
            c.next();
        },
        '$' => {
            if (c.cursor == c.raw.len - 1) {
                try c.instAssert(.end_line_or_string);
            } else return error.UnsupportedClass;
            c.next();
        },
        '+', '?', '*' => return error.MissingRepeatArgument,
        '|', ')' => unreachable,
        else => {
            try c.instMatch(.{ .char = c.peek() }, c.inst.items.len + 1, 0);
            return c.next();
        },
    }
}

fn compileRepetition(c: *Compiler) !void {
    const start_idx = c.inst.items.len;
    try c.compileAtom(false);

    if (c.cursor >= c.raw.len) return;
    switch (c.peek()) {
        '+' => {
            try c.split(start_idx, c.inst.items.len + 1);
            c.next();
        },
        '?' => {
            // char group and capture group both have a "start group" inst
            c.inst.items[start_idx].alt = @intCast(c.inst.items.len);
            c.next();
        },
        '*' => {
            // char group and capture group both have a "start group" inst
            c.inst.items[start_idx].alt = @intCast(c.inst.items.len + 1);
            try c.split(start_idx, c.inst.items.len + 1);
            c.next();
        },
        else => return,
    }
}

fn compileConcat(c: *Compiler) !void {
    while (c.cursor < c.raw.len) {
        if (c.peek() == '|' or c.peek() == ')') return;
        try c.compileRepetition();
    }
}

fn compileAlternation(c: *Compiler) !void {
    const split_idx = c.inst.items.len;
    try c.split(split_idx + 1, 0); // alt to be patched
    try c.compileConcat();
    if (c.cursor < c.raw.len and c.peek() == '|') {
        c.inst.items[split_idx].alt = @intCast(c.inst.items.len);
        c.next();
        const last_alt = c.inst.items.len - 1;
        try c.compileAlternation();
        c.inst.items[last_alt].next = @intCast(c.inst.items.len);
    }
}

inline fn peek(c: *Compiler) u8 {
    return c.raw[c.cursor];
}

inline fn next(c: *Compiler) void {
    c.cursor += 1;
}

inline fn split(c: *Compiler, next_idx: usize, alt_idx: usize) !void {
    try c.inst.append(.{
        .op = .split,
        .next = @intCast(next_idx),
        .alt = @intCast(alt_idx),
    });
}

inline fn instMatch(c: *Compiler, m: Pattern, next_idx: usize, alt_idx: usize) !void {
    try c.inst.append(.{
        .op = .{ .match = @intCast(c.patterns.items.len) },
        .next = @intCast(next_idx),
        .alt = @intCast(alt_idx),
    });
    try c.patterns.append(m);
}

inline fn instAssert(c: *Compiler, anchor: Inst.Anchor) !void {
    try c.inst.append(.{
        .op = .{ .assert = anchor },
        .next = @intCast(c.inst.items.len + 1),
    });
}

fn escapedChar(c: *Compiler) !void {
    if (c.cursor + 1 >= c.raw.len) return error.UnexpectedEOF;
    c.next();
    const next_inst = c.inst.items.len + 1;
    switch (c.peek()) {
        // char class
        'd' => try c.instMatch(.{ .func = &isDigit }, next_inst, 0),
        'w' => try c.instMatch(.{ .func = &isAlphanumeric }, next_inst, 0),

        // white space
        't' => try c.instMatch(.{ .char = cc.bs }, next_inst, 0),
        'r' => try c.instMatch(.{ .char = cc.cr }, next_inst, 0),
        'v' => try c.instMatch(.{ .char = cc.vt }, next_inst, 0),
        'f' => try c.instMatch(.{ .char = cc.ff }, next_inst, 0),
        'n' => try c.instMatch(.{ .char = cc.lf }, next_inst, 0),
        'e' => try c.instMatch(.{ .char = cc.esc }, next_inst, 0),
        's' => try c.instMatch(.{ .func = &isWhitespace }, next_inst, 0),

        // escaped
        '-', '|', '*', '+', '?', '(', ')' => |ch| try c.instMatch(.{ .char = ch }, next_inst, 0),

        // backref
        '1'...'9' => try c.backref(),

        // anchor
        'b' => try c.instAssert(.word_boundary),
        'B' => try c.instAssert(.non_word_boundary),
        else => return error.UnexpectedEOF,
    }
    c.next();
}

fn charRange(c: *Compiler) !void {
    const prev = c.raw[c.cursor - 1];
    c.next(); // '-'
    if (c.cursor >= c.raw.len) return error.MissingBracket;
    const to = c.raw[c.cursor];

    // '-' is matched literally
    if (prev == '[' or
        (prev == '^' and c.raw[c.cursor - 3] == '[') or // safe because in_char_group == true
        to == ']')
        return c.instMatch(.{ .char = '-' }, c.inst.items.len + 1, 0);

    c.next(); // consume the 'to' char
    const from_pattern = &c.patterns.items[c.patterns.items.len - 1];
    const from: u8 = blk: switch (from_pattern.*) {
        .char => |char| break :blk char,
        else => return error.InvalidCharRange,
    };

    if (from > to) return error.InvalidCharRange;

    from_pattern.* = .{ .range = .{ .from = from, .to = to } };
}

fn charGroup(c: *Compiler) !void {
    c.next(); // '['
    if (c.cursor >= c.raw.len) return error.UnexpectedEOF;
    const negated = c.peek() == '^';
    if (negated) c.next(); // '^'

    try c.split(c.inst.items.len + 1, 0);
    const start = c.inst.items.len;

    while (c.cursor < c.raw.len) {
        if (c.raw[c.cursor] == ']') {
            c.next(); // ']'
            break;
        }
        try c.compileAtom(true);
    } else return error.MissingBracket;

    const group_next: u32 = @intCast(c.inst.items.len);
    var i: u32 = @intCast(start);
    if (!negated) {
        // patch each inst
        while (i < group_next) : (i += 1) {
            c.inst.items[i].next = group_next;
            c.inst.items[i].alt = i + 1;
        }
        // for last inst of group, no more alt
        c.inst.items[group_next - 1].alt = 0;
    } else {
        while (i < group_next) : (i += 1) {
            // if matched inst should return false
            c.inst.items[i].next = 0;
            // if not matched (aka alt) try again with next inst
            c.inst.items[i].alt = i + 1;
        }
        // at last inst, if not matched then none of the negative patterns matched
        // add inst to consume current input char (which last inst is pointing to)
        try c.instMatch(.{ .func = &isAny }, group_next + 1, 0);
    }
}

fn captureGroup(c: *Compiler) !void {
    c.next(); // '('
    const group_num = c.group_count;
    c.group_count += 1;

    try c.inst.append(.{
        .op = .{ .group_start = group_num },
        .next = @intCast(c.inst.items.len + 1),
    });
    try c.compileAlternation();

    if (c.cursor >= c.raw.len or c.raw[c.cursor] != ')')
        return error.MissingParen;
    c.next(); // ')'

    try c.inst.append(.{
        .op = .{ .group_end = group_num },
        .next = @intCast(c.inst.items.len + 1),
    });
}

fn backref(c: *Compiler) !void {
    const num_start = c.cursor;
    while (c.cursor < c.raw.len and isDigit(c.peek())) : (c.cursor += 1) {}
    const num = std.fmt.parseInt(u32, c.raw[num_start..c.cursor], 10) catch
        return error.InvalidBackReference;
    if (num > c.group_count) return error.InvalidBackReference;

    // to account for the automatic next() at the end of escapedChar()
    c.cursor -= 1;

    try c.inst.append(.{ .op = .{ .backref = num }, .next = @intCast(c.inst.items.len + 1) });
}

pub const Pattern = union(enum) {
    char: u8,
    range: Range,
    func: *const fn (u8) bool,

    const Range = struct {
        from: u8,
        to: u8,
    };
};

fn isDigit(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

pub fn isAlphanumeric(c: u8) bool {
    return switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

pub fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t'...'\r' => true,
        else => false,
    };
}

fn isAny(_: u8) bool {
    return true;
}

pub const Inst = struct {
    op: Op,
    next: u32,
    alt: u32 = 0,

    const Op = union(enum) {
        // match patterns[idx]
        match: u32,
        assert: Anchor,
        nil,
        end,
        split,
        // group number of the capture text
        group_start: u32,
        group_end: u32,
        // group number to reference
        backref: u32,
    };

    const Anchor = enum {
        start_line_or_string,
        end_line_or_string,
        word_boundary,
        non_word_boundary,
    };
};
