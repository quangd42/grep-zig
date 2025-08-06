const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const testing = std.testing;

const Regex = @This();

pub const Inst = struct {
    /// match the patterns at idx..idx+len
    idx: usize,
    len: usize = 1,
    negated: bool = false,
    quantifier: Quantifier = .{ .min = 1, .max = 1 },

    const Quantifier = struct {
        min: usize,
        max: usize,
    };
};

pub const Pattern = union(enum) {
    char: u8,
    class: *const fn (u8) bool,

    pub fn match(p: Pattern, target: u8) bool {
        return switch (p) {
            .char => |c| c == target,
            .class => |cl| cl(target),
        };
    }
};

const Anchors = struct {
    start: bool,
    end: bool,
};

raw: []const u8,
input: []const u8 = &[_]u8{},

cursor: usize = 0,
inst: std.ArrayList(Inst),
patterns: std.ArrayList(Pattern),
anchors: Anchors,

pub fn init(gpa: Allocator, raw: []const u8) !Regex {
    var out = Regex{
        .raw = raw,
        .inst = .init(gpa),
        .patterns = .init(gpa),
        .anchors = .{ .start = false, .end = false },
    };
    try out.compile();
    return out;
}

pub fn deinit(p: *Regex) void {
    p.inst.deinit();
    p.patterns.deinit();
}

fn compile(p: *Regex) !void {
    while (p.cursor < p.raw.len) : (p.cursor += 1) {
        switch (p.raw[p.cursor]) {
            '\\' => {
                try p.inst.append(.{ .idx = p.patterns.items.len });
                try p.escapedChar();
                p.quantifiers();
            },
            '[' => try p.charGroup(),
            '^' => {
                if (p.cursor != 0) return error.InvalidAnchor;
                p.anchors.start = true;
            },
            '$' => {
                if (p.cursor != p.raw.len - 1) return error.InvalidAnchor;
                p.anchors.end = true;
            },
            '.' => {
                try p.inst.append(.{ .idx = p.patterns.items.len });
                p.cursor += 1;
                try p.patterns.append(.{ .class = &isAny });
            },
            else => {
                try p.inst.append(.{ .idx = p.patterns.items.len });
                try p.char();
                p.quantifiers();
            },
        }
    }
}

fn eatChar(p: *Regex, c: u8) bool {
    if (p.raw[p.cursor] == c) {
        p.cursor += 1;
        return true;
    }
    return false;
}

fn char(p: *Regex) !void {
    try p.patterns.append(.{ .char = p.raw[p.cursor] });
}

fn escapedChar(p: *Regex) !void {
    if (p.cursor + 1 >= p.raw.len) return error.UnfinishedClass;
    p.cursor += 1;
    try p.patterns.append(switch (p.raw[p.cursor]) {
        'd' => .{ .class = &isDigit },
        'w' => .{ .class = &isAlphanumeric },
        else => return error.UnhandledClass,
    });
}

// Only parsing one quantifier for now
fn quantifiers(p: *Regex) void {
    if (p.cursor + 1 >= p.raw.len) return;
    var last_inst = &p.inst.items[p.inst.items.len - 1];
    switch (p.raw[p.cursor + 1]) {
        '+' => {
            last_inst.quantifier = .{ .min = 1, .max = 0 };
        },
        '?' => {
            last_inst.quantifier = .{ .min = 0, .max = 1 };
        },
        else => return,
    }
    p.cursor += 1;
}

fn charGroup(p: *Regex) !void {
    p.cursor += 1; // '['
    if (p.cursor >= p.raw.len) return error.UnfinishedClass;
    const negated = p.eatChar('^');
    const idx = p.patterns.items.len;
    try p.inst.append(.{ .idx = idx });
    const inst_idx = p.inst.items.len - 1;
    var len: usize = 0;
    while (p.raw[p.cursor] != ']') : (p.cursor += 1) {
        if (p.cursor >= p.raw.len) return error.UnfinishedClass;
        switch (p.raw[p.cursor]) {
            '\\' => try p.escapedChar(),
            else => try p.char(),
        }
        len += 1;
    }
    p.inst.items[inst_idx] = .{
        .idx = idx,
        .len = len,
        .negated = negated,
    };
    p.quantifiers();
}

fn isDigit(c: u8) bool {
    return ascii.isDigit(c);
}

fn isAlphanumeric(c: u8) bool {
    return c == '_' or ascii.isAlphanumeric(c);
}

fn isAny(_: u8) bool {
    return true;
}

test "compile" {
    const gpa = testing.allocator;
    var p = try Regex.init(gpa, "\\dab[\\dab]");
    defer p.deinit();
    const inst = &p.inst.items;
    const patt = &p.patterns.items;

    try testing.expect(inst.len == 4);

    try testing.expect(patt.len == 6);
    try testing.expect(patt.*[0].class == &isDigit);
    try testing.expect(patt.*[1].char == 'a');
    try testing.expect(patt.*[2].char == 'b');
}

fn matchInst(re: *Regex, inst: Inst, target: u8) bool {
    for (re.patterns.items[inst.idx..][0..inst.len]) |pattern| {
        if (pattern.match(target)) return !inst.negated;
    }
    return inst.negated;
}

fn matchAt2(re: *Regex, start_at: usize) bool {
    var input_idx = start_at;
    const instructions = re.inst.items;
    if (instructions.len > re.input.len - start_at) return false;
    for (instructions) |inst| {
        const target = re.input[input_idx];
        // const min = inst.quantifier.min;
        // const max = inst.quantifier.max;
        // var count: usize = 0;
        if (re.matchInst(inst, target)) {
            input_idx += 1;
            continue;
        }
        return false;
    }
    return true;
}

fn matchAt(re: *Regex, input_i: usize, inst_i: usize) bool {
    if (re.input.len == 0) return false;
    if (inst_i >= re.inst.items.len) {
        if (re.anchors.end and input_i < re.input.len) return false;
        return true;
    }
    if (input_i >= re.input.len) return false;

    const target = re.input[input_i];
    const inst = re.inst.items[inst_i];
    const min = inst.quantifier.min;
    const max = inst.quantifier.max;
    if (max == 0 and min == 1) {
        if (re.matchInst(inst, target)) {
            if (re.matchAt(input_i + 1, inst_i)) return true;
            return re.matchAt(input_i + 1, inst_i + 1);
        }
    }
    if (re.matchInst(inst, target)) {
        return re.matchAt(input_i + 1, inst_i + 1);
    }
    // this order means greedy match
    if (min == 0) {
        return re.matchAt(input_i, inst_i + 1);
    }
    return false;
}

pub fn match(re: *Regex, input: []const u8) bool {
    re.input = input;
    if (re.anchors.start)
        return re.matchAt(0, 0);

    for (0..input.len) |i| {
        if (re.matchAt(i, 0)) return true;
    }
    return false;
}

test "match char and escaped char" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const raw = "\\dab";
    const input = "0123abc";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();
    try expect(re.match(input));

    const raw2 = "\\wbc";
    var re2 = try Regex.init(gpa, raw2);
    defer re2.deinit();
    try expect(re2.match(input));
}

test "match character group" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const raw3 = "[1a] apple";
    const input3a = "1 apple";
    const input3b = "a apple";
    const input3c = "b apple";
    var re3 = try Regex.init(gpa, raw3);
    defer re3.deinit();
    try expect(re3.patterns.items.len == 8);
    try expect(re3.match(input3a));
    try expect(re3.match(input3b));
    try expect(!re3.match(input3c));

    const raw4 = "[^1a] apple";
    var re4 = try Regex.init(gpa, raw4);
    defer re4.deinit();
    try expect(re4.match(input3c));
    try expect(!re4.match(input3a));
    try expect(!re4.match(input3b));
}

test "match anchors" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const long = "logloglog";
    const short = "log";
    const raw5 = "^log";
    var re5 = try Regex.init(gpa, raw5);
    defer re5.deinit();
    try expect(re5.match(short));
    try expect(re5.match(long));

    const raw6 = "log$";
    var re6 = try Regex.init(gpa, raw6);
    defer re6.deinit();
    try expect(re6.match(short));
    try expect(re5.match(long));
}

test "quantifier" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const input = "cats";

    const raw = "ca+ts";
    const input1 = "caats";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();
    try expect(re.inst.items[1].quantifier.min == 1);
    try expect(re.inst.items[1].quantifier.max == 0);
    try expect(re.match(input));
    try expect(re.match(input1));

    const raw2 = "ca?ts";
    const input2 = "cts";
    var re2 = try Regex.init(gpa, raw2);
    defer re2.deinit();
    try expect(re2.match(input));
    try expect(re2.match(input2));
}

test "match wildcard" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const input = "log";
    const raw = "l.g";
    const input1 = "lot";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();
    try expect(re.match(input));
    try expect(!re.match(input1));

    const raw2 = ".og";
    var re2 = try Regex.init(gpa, raw2);
    defer re2.deinit();
    try expect(re2.match(input));

    const raw3 = "lo.";
    var re3 = try Regex.init(gpa, raw3);
    defer re3.deinit();
    try expect(re3.match(input));
}
