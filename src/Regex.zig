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
        char: u8,
        class: *const fn (u8) bool,
        nil,
        end,

        pub fn match(p: Op, target: u8) bool {
            return switch (p) {
                .char => |c| c == target,
                .class => |cl| cl(target),
            };
        }
    };
};

const Anchors = struct {
    start: bool,
    end: bool,
};

raw: []const u8,
input: []const u8 = &[_]u8{},

cursor: usize = 0,
inst: std.ArrayList(Inst),
anchors: Anchors,

const Error = error{ OutOfMemory, InvalidAnchor, UnfinishedClass, UnhandledClass };

pub fn init(gpa: Allocator, raw: []const u8) !Regex {
    var out = Regex{
        .raw = raw,
        .inst = .init(gpa),
        .anchors = .{ .start = false, .end = false },
    };
    try out.compile();
    return out;
}

pub fn deinit(re: *Regex) void {
    re.inst.deinit();
}

fn compile(re: *Regex) !void {
    // reserving first inst as nil
    try re.inst.append(.{ .op = .nil, .next = 0 });

    while (re.cursor < re.raw.len) {
        try re.nextInst();
    }

    try re.inst.append(.{ .op = .end, .next = 0 });
}

fn nextInst(re: *Regex) Error!void {
    if (re.cursor >= re.raw.len) return;
    defer re.cursor += 1;

    switch (re.raw[re.cursor]) {
        '\\' => try re.escapedChar(),
        '[' => try re.charGroup(),
        '^' => {
            if (re.cursor != 0) return error.InvalidAnchor;
            re.anchors.start = true;
        },
        '$' => {
            if (re.cursor != re.raw.len - 1) return error.InvalidAnchor;
            re.anchors.end = true;
        },
        '.' => {
            try re.inst.append(.{
                .op = .{ .class = &isAny },
                .next = re.inst.items.len + 1,
            });
        },
        else => try re.inst.append(.{
            .op = .{ .char = re.raw[re.cursor] },
            .next = re.inst.items.len + 1,
        }),
    }
}

fn eatChar(p: *Regex, c: u8) bool {
    if (p.raw[p.cursor] == c) {
        p.cursor += 1;
        return true;
    }
    return false;
}

fn escapedChar(re: *Regex) !void {
    if (re.cursor + 1 >= re.raw.len) return error.UnfinishedClass;
    re.cursor += 1;
    const next = re.inst.items.len + 1;
    try re.inst.append(switch (re.raw[re.cursor]) {
        'd' => .{ .op = .{ .class = &isDigit }, .next = next },
        'w' => .{ .op = .{ .class = &isAlphanumeric }, .next = next },
        else => return error.UnhandledClass,
    });
}

fn charGroup(re: *Regex) !void {
    re.cursor += 1; // '['
    if (re.cursor >= re.raw.len) return error.UnfinishedClass;
    const negated = re.eatChar('^');
    const start = re.inst.items.len;

    while (re.raw[re.cursor] != ']') {
        if (re.cursor >= re.raw.len) return error.UnfinishedClass;
        // for each candidate pattern, emit a jump
        // jump.next = candidate pattern
        // jump.alt = next split
        // cand.next = group_next

        try re.nextInst();
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
        // if matched should return false, so next = 0
        // if not matched (aka alt) try again with next inst, so alt should be i + 1
        while (i < group_next) : (i += 1) {
            re.inst.items[i].next = 0;
            re.inst.items[i].alt = i + 1;
        }
        // at last inst, if not matched then char group is over
        // add inst that consume current input char (which last inst is pointing to)
        try re.inst.append(.{
            .op = .{ .class = &isAny },
            .next = group_next + 1,
            .alt = 0,
        });
    }
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
    var re = try Regex.init(gpa, "\\dab[\\dab]");
    defer re.deinit();
    const inst = re.inst.items;

    try testing.expectEqual(6, re.inst.items.len - 2);
    try testing.expect(inst[0].op.nil == {});
    try testing.expect(inst[re.inst.items.len - 1].op.end == {});

    try testing.expect(inst[1].op.class == &isDigit);
    try testing.expect(inst[2].op.char == 'a');
    try testing.expect(inst[3].op.char == 'b');
}

fn matchInst(re: *Regex, inst: Inst, target: u8) bool {
    for (re.patterns.items[inst.idx..][0..inst.len]) |pattern| {
        if (pattern.match(target)) return !inst.negated;
    }
    return inst.negated;
}

fn matchAt(re: *Regex, input_idx: usize, inst_idx: usize) bool {
    if (re.inst.items.len == 0) return true; // nothing to match
    assert(inst_idx < re.inst.items.len); // all inst should never point past op.end

    // if (input_idx < re.input.len) std.debug.print("input_idx = {d}, char = {c}, inst_idx = {d}, inst = {any}\n", .{ input_idx, re.input[input_idx], inst_idx, re.inst.items[inst_idx] });

    const inst = re.inst.items[inst_idx];
    return switch (inst.op) {
        .nil => return false,
        .end => {
            // Found a path to the end state.
            // return input_idx >= re.input.len; ???
            if (re.anchors.end and input_idx != re.input.len) return false;
            return true;
        },
        .char => |c| {
            if (input_idx >= re.input.len) return false; // not enough input to match pattern
            if (re.input[input_idx] == c) {
                return re.matchAt(input_idx + 1, inst.next);
            }
            return re.matchAt(input_idx, inst.alt);
        },
        .class => |cl| {
            if (input_idx >= re.input.len) return false; // not enough input to match pattern
            if (cl(re.input[input_idx])) {
                return re.matchAt(input_idx + 1, inst.next);
            }
            return re.matchAt(input_idx, inst.alt);
        },
    };
}

pub fn match(re: *Regex, input: []const u8) bool {
    re.input = input;
    if (re.anchors.start)
        return re.matchAt(0, 1);

    for (0..input.len) |i| {
        if (re.matchAt(i, 1)) return true;
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

// test "quantifier" {
//     const expect = testing.expect;
//     const gpa = testing.allocator;
//
//     const input = "cats";
//
//     const raw = "ca+ts";
//     const input1 = "caats";
//     var re = try Regex.init(gpa, raw);
//     defer re.deinit();
//     try expect(re.inst.items[1].quantifier.min == 1);
//     try expect(re.inst.items[1].quantifier.max == 0);
//     try expect(re.match(input));
//     try expect(re.match(input1));
//
//     const raw2 = "ca?ts";
//     const input2 = "cts";
//     var re2 = try Regex.init(gpa, raw2);
//     defer re2.deinit();
//     try expect(re2.match(input));
//     try expect(re2.match(input2));
// }

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

// test "match groups with alternation" {
//     const expect = testing.expect;
//     const gpa = testing.allocator;
//
//     const raw = "(abl|cde)123";
//     var re = try Regex.init(gpa, raw);
//     defer re.deinit();
//
//     try expect(re.match("abl123"));
//     try expect(re.match("cde123"));
//     try expect(!re.match("abc123"));
//     try expect(!re.match("xyz123"));
//
//     const raw2 = "x(a|b|c)y";
//     var re2 = try Regex.init(gpa, raw2);
//     defer re2.deinit();
//
//     try expect(re2.match("xay"));
//     try expect(re2.match("xby"));
//     try expect(re2.match("xcy"));
//     try expect(!re2.match("xdy"));
// }
