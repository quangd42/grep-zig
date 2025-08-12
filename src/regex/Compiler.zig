const std = @import("std");
const Allocator = std.mem.Allocator;

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
cursor: usize = 0,
group_count: usize = 0,
anchors: Anchors = .{ .start = false, .end = false },

pub fn init(gpa: Allocator, raw: []const u8) Compiler {
    return .{
        .raw = raw,
        .inst = .init(gpa),
    };
}

pub fn deinit(c: *Compiler) void {
    c.inst.deinit();
}

pub fn compile(c: *Compiler) !void {
    // reserving first inst as nil
    try c.inst.append(.{ .op = .nil, .next = 0 });
    if (c.raw[c.cursor] == '^') {
        c.anchors.start = true;
        c.cursor += 1;
    }

    try c.compileAlternation();

    try c.inst.append(.{ .op = .end, .next = 0 });
}

fn compileAtom(c: *Compiler, in_char_group: bool) Error!void {
    if (c.cursor >= c.raw.len) return;

    switch (c.peek()) {
        '\\' => try c.escapedChar(),
        '[' => try c.charGroup(),
        '.' => {
            try c.matchChar(.{ .func = &isAny }, c.inst.items.len + 1, 0);
            c.next();
        },
        '(' => try c.captureGroup(),
        '-' => {
            if (!in_char_group) {
                try c.matchChar(.{ .char = c.peek() }, c.inst.items.len + 1, 0);
                return c.next();
            }

            try c.charRange();
        },
        '$' => {
            if (c.cursor == c.raw.len - 1) {
                c.anchors.end = true;
            } else return error.UnsupportedClass;
            c.next();
        },
        '+', '?', '*' => return error.MissingRepeatArgument,
        '|', ')' => unreachable,
        else => {
            try c.matchChar(.{ .char = c.peek() }, c.inst.items.len + 1, 0);
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
            c.inst.items[start_idx].alt = c.inst.items.len;
            c.next();
        },
        '*' => {
            // char group and capture group both have a "start group" inst
            c.inst.items[start_idx].alt = c.inst.items.len + 1;
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
        c.inst.items[split_idx].alt = c.inst.items.len;
        c.next();
        const last_alt = c.inst.items.len - 1;
        try c.compileAlternation();
        c.inst.items[last_alt].next = c.inst.items.len;
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
        .next = next_idx,
        .alt = alt_idx,
    });
}

inline fn matchChar(c: *Compiler, m: Pattern, next_idx: usize, alt_idx: usize) !void {
    try c.inst.append(.{
        .op = .{ .match = m },
        .next = next_idx,
        .alt = alt_idx,
    });
}

fn escapedChar(c: *Compiler) !void {
    if (c.cursor + 1 >= c.raw.len) return error.UnexpectedEOF;
    c.next();
    const next_inst = c.inst.items.len + 1;
    switch (c.peek()) {
        'd' => try c.matchChar(.{ .func = &isDigit }, next_inst, 0),
        'w' => try c.matchChar(.{ .func = &isAlphanumeric }, next_inst, 0),
        '-', '|', '*', '+', '?', '(', ')' => |ch| try c.matchChar(.{ .char = ch }, next_inst, 0),
        '1'...'9' => try c.backref(),
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
        return c.matchChar(.{ .char = '-' }, c.inst.items.len + 1, 0);

    c.next(); // consume the 'to' char
    const from_inst = &c.inst.items[c.inst.items.len - 1];
    const from: u8 = blk: switch (from_inst.op) {
        .match => |m| switch (m) {
            .char => |char| break :blk char,
            else => return error.InvalidCharRange,
        },
        else => return error.InvalidCharRange,
    };

    if (from > to) return error.InvalidCharRange;

    from_inst.op = .{ .match = .{ .range = .{ .from = from, .to = to } } };
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

    const group_next = c.inst.items.len;
    var i = start;
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
        try c.inst.append(.{
            .op = .{ .match = .{ .func = &isAny } },
            .next = group_next + 1,
            .alt = 0,
        });
    }
}

fn captureGroup(c: *Compiler) !void {
    c.next(); // '('
    const group_num = c.group_count;
    c.group_count += 1;

    try c.inst.append(.{
        .op = .{ .group_start = group_num },
        .next = c.inst.items.len + 1,
    });
    try c.compileAlternation();

    if (c.cursor >= c.raw.len or c.raw[c.cursor] != ')')
        return error.MissingParen;
    c.next(); // ')'

    try c.inst.append(.{
        .op = .{ .group_end = group_num },
        .next = c.inst.items.len + 1,
    });
}

fn backref(c: *Compiler) !void {
    const num_start = c.cursor;
    while (c.cursor < c.raw.len and isDigit(c.peek())) : (c.cursor += 1) {}
    const num = std.fmt.parseInt(usize, c.raw[num_start..c.cursor], 10) catch
        return error.InvalidBackReference;
    if (num > c.group_count) return error.InvalidBackReference;

    // to account for the automatic next() at the end of escapedChar()
    c.cursor -= 1;

    try c.inst.append(.{ .op = .{ .backref = num }, .next = c.inst.items.len + 1 });
}

pub const Anchors = struct {
    start: bool,
    end: bool,
};

pub const Pattern = union(enum) {
    char: u8,
    range: Range,
    func: *const fn (u8) bool,

    const Range = struct {
        from: u8,
        to: u8,
    };

    pub fn match(s: Pattern, char: u8) bool {
        return switch (s) {
            .char => |c| char == c,
            .range => |r| r.from <= char and r.to >= char,
            .func => |f| f(char),
        };
    }
};

fn isDigit(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

fn isAlphanumeric(c: u8) bool {
    return switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isAny(_: u8) bool {
    return true;
}

pub const Inst = struct {
    /// match the patterns at idx..idx+len
    op: Op,
    next: usize,
    alt: usize = 0,

    const Op = union(enum) {
        match: Pattern,
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
            .match => |p| {
                switch (p) {
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
