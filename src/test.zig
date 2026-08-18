const std = @import("std");
const Parser = @import("zflag");
const Arg = Parser.Arg;
const Flag = Parser.Flag;

fn getParser() Parser {
    return .{
        .positional_args = &.{
            Arg{
                .name = "directory",
                .description = "Directory(ies) to create",
                .type = .{ .array = .{ .child = .string } },
            },
        },
        .flags = &.{
            Flag{
                .short = 'p',
                .long = "parents",
                .description = "no error if existing, make parent directories as needed",
                .type = .{ .boolean = .{ .default = false } },
            },
            Parser.HelpFlag,
        },
    };
}

test "parse multiple directories with short flag" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{ "a", "b", "c", "-p" }, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 3), directories.items.len);
    try std.testing.expectEqualStrings("a", directories.items[0]);
    try std.testing.expectEqualStrings("b", directories.items[1]);
    try std.testing.expectEqualStrings("c", directories.items[2]);

    const parent = result.getFlagResult("parents").?.parsed.boolean;
    try std.testing.expect(parent);
}

test "parse multiple directories with long flag" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{ "dir1", "dir2", "--parents" }, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 2), directories.items.len);
    try std.testing.expectEqualStrings("dir1", directories.items[0]);
    try std.testing.expectEqualStrings("dir2", directories.items[1]);

    const parent = result.getFlagResult("parents").?.parsed.boolean;
    try std.testing.expect(parent);
}

test "parse single directory without flags" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{"single"}, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 1), directories.items.len);
    try std.testing.expectEqualStrings("single", directories.items[0]);

    const parent = result.getFlagResult("parents").?.parsed.boolean;
    try std.testing.expect(!parent);
}

test "parse with flag before arguments" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{ "-p", "path1", "path2", "path3" }, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 3), directories.items.len);
    try std.testing.expectEqualStrings("path1", directories.items[0]);
    try std.testing.expectEqualStrings("path2", directories.items[1]);
    try std.testing.expectEqualStrings("path3", directories.items[2]);

    const parent = result.getFlagResult("parents").?.parsed.boolean;
    try std.testing.expect(parent);
}

test "parse with flag in middle of arguments" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{ "dir1", "-p", "dir2" }, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 2), directories.items.len);
    try std.testing.expectEqualStrings("dir1", directories.items[0]);
    try std.testing.expectEqualStrings("dir2", directories.items[1]);

    const parent = result.getFlagResult("parents").?.parsed.boolean;
    try std.testing.expect(parent);
}

test "parse multiple directories without flags" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{ "x", "y", "z" }, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 3), directories.items.len);
    try std.testing.expectEqualStrings("x", directories.items[0]);
    try std.testing.expectEqualStrings("y", directories.items[1]);
    try std.testing.expectEqualStrings("z", directories.items[2]);

    const parent = result.getFlagResult("parents").?.parsed.boolean;
    try std.testing.expect(!parent);
}

test "parse with nested directory paths" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{ "foo/bar", "baz/qux/quux", "-p" }, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 2), directories.items.len);
    try std.testing.expectEqualStrings("foo/bar", directories.items[0]);
    try std.testing.expectEqualStrings("baz/qux/quux", directories.items[1]);

    const parent = result.getFlagResult("parents").?.parsed.boolean;
    try std.testing.expect(parent);
}

test "parse with hidden directory names" {
    const parser = getParser();
    var result = try parser.parse(std.testing.allocator, &.{ ".hidden", "..parent", ".config" }, .{});
    defer result.deinit(std.testing.allocator);

    const directories = result.getArgResult("directory").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 3), directories.items.len);
    try std.testing.expectEqualStrings(".hidden", directories.items[0]);
    try std.testing.expectEqualStrings("..parent", directories.items[1]);
    try std.testing.expectEqualStrings(".config", directories.items[2]);
}
