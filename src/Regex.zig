const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const testing = std.testing;
const Regex = @This();

pub const Inst = union(enum) {
    single_char: usize,
    class: struct {
        idx: usize,
        len: usize = 1,
        negated: bool = false,
    },
};

pub const Pattern = union(enum) {
    char: u8,
    class: *const fn (u8) bool,
};

raw: []const u8,
cursor: usize = 0,
inst: std.ArrayList(Inst),
patterns: std.ArrayList(Pattern),

pub fn init(gpa: Allocator, raw: []const u8) !Regex {
    var out = Regex{
        .raw = raw,
        .inst = .init(gpa),
        .patterns = .init(gpa),
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
                try p.inst.append(.{ .class = .{ .idx = p.patterns.items.len } });
                try p.escapedChar();
            },
            '[' => try p.charGroup(),
            else => {
                try p.inst.append(.{ .single_char = p.patterns.items.len });
                try p.char();
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

fn charGroup(p: *Regex) !void {
    p.cursor += 1; // '['
    if (p.cursor >= p.raw.len) return error.UnfinishedClass;
    const negated = p.eatChar('^');
    const idx = p.patterns.items.len;
    try p.inst.append(.{ .class = undefined });
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
    p.inst.items[inst_idx].class = .{
        .idx = idx,
        .len = len,
        .negated = negated,
    };
}

fn isDigit(c: u8) bool {
    return ascii.isDigit(c);
}

fn isAlphanumeric(c: u8) bool {
    return c == '_' or ascii.isAlphanumeric(c);
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

pub fn matchAt(re: *Regex, idx: usize, full_input: []const u8) bool {
    const input = full_input[idx..];
    const instructions = re.inst.items;
    const patterns = re.patterns.items;
    if (instructions.len > input.len) return false;
    main_loop: for (instructions, input[0..instructions.len]) |inst, target| {
        switch (inst) {
            .single_char => |p_idx| if (patterns[p_idx].char != target) return false,
            .class => |data| {
                if (!data.negated) {
                    for (patterns[data.idx..][0..data.len]) |pattern| {
                        switch (pattern) {
                            .char => |p| if (p == target) continue :main_loop,
                            .class => |p| if (p(target)) continue :main_loop,
                        }
                    }
                    return false;
                } else {
                    for (patterns[data.idx..][0..data.len]) |pattern| {
                        switch (pattern) {
                            .char => |p| if (p == target) return false,
                            .class => |p| if (p(target)) return false,
                        }
                    }
                }
            },
        }
    }
    return true;
}

pub fn match(re: *Regex, input: []const u8) bool {
    const max_i = input.len - re.inst.items.len + 1;
    for (0..max_i) |i| {
        if (re.matchAt(i, input)) return true;
    }
    return false;
}

test "matcher" {
    const expect = testing.expect;
    const gpa = testing.allocator;

    const raw = "\\dab";
    const input = "0123abc";
    var re = try Regex.init(gpa, raw);
    defer re.deinit();
    try expect(!re.matchAt(0, input));
    try expect(re.matchAt(3, input));

    try expect(re.match(input));

    const raw2 = "\\wbc";
    var re2 = try Regex.init(gpa, raw2);
    defer re2.deinit();
    try expect(re2.matchAt(4, input));
    try expect(!re2.matchAt(0, input));
    try expect(re2.match(input));

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
