const std = @import("std");
const testing = std.testing;
const matchPattern = @import("main.zig").matchPattern;

test "match digits" {
    const pattern = "\\d";
    const input1 = "apple123";
    const input2 = "apple";
    try testing.expect(matchPattern(input1, pattern));
    try testing.expect(!matchPattern(input2, pattern));
}

test "match alphanumeric" {
    const pattern = "\\w";
    const input1 = "alpha-num3ric";
    const input2 = "$!?";
    try testing.expect(matchPattern(input1, pattern));
    try testing.expect(!matchPattern(input2, pattern));
}

test "positive character group" {
    const pattern = "[abc]";
    const input1 = "apple";
    const input2 = "outside";
    try testing.expect(matchPattern(input1, pattern));
    try testing.expect(!matchPattern(input2, pattern));
}
