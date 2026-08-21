const std = @import("std");
const zflag = @import("zflag");

fn parseArgs(
    parser: zflag.Parser,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !zflag.ParsedResults {
    return parser.parse(allocator, args, .{});
}

fn deinitParsed(results: *zflag.ParsedResults, allocator: std.mem.Allocator) void {
    results.deinit(allocator, .{ .free_arrays = true });
}

test "scalar flags parse values and preserve defaults" {
    const parser: zflag.Parser = .{
        .flags = &.{
            .{ .short = 'n', .long = "number", .description = "", .type = .{ .int = .{ .default = 7 } } },
            .{ .long = "enabled", .description = "", .type = .{ .boolean = .{ .default = false } } },
            .{ .long = "ratio", .description = "", .type = .{ .float = .{} } },
            .{ .long = "name", .description = "", .type = .{ .string = .{} } },
        },
    };
    var results = try parseArgs(parser, std.testing.allocator, &.{ "--number=0x10", "-enabled", "--ratio", "1.5", "--name=value" });
    defer deinitParsed(&results, std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 16), results.getFlag("number").?.parsed.int);
    try std.testing.expect(results.getFlag("number").?.user_input);
    try std.testing.expect(results.getFlag("enabled").?.parsed.boolean);
    try std.testing.expectEqual(@as(f64, 1.5), results.getFlag("ratio").?.parsed.float);
    try std.testing.expectEqualStrings("value", results.getFlag("name").?.parsed.string);

    const default_parser: zflag.Parser = .{
        .flags = &.{.{ .long = "number", .description = "", .type = .{ .int = .{ .default = 7 } } }},
    };
    var defaults = try parseArgs(default_parser, std.testing.allocator, &.{});
    defer deinitParsed(&defaults, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 7), defaults.getFlag("number").?.parsed.int);
    try std.testing.expect(!defaults.getFlag("number").?.user_input);
}

test "boolean values accept explicit forms" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .long = "value", .description = "", .type = .{ .boolean = .{} } }},
    };
    const cases = [_][]const u8{ "true", "TRUE", "1", "false", "FALSE", "0" };
    const expected = [_]bool{ true, true, true, false, false, false };
    for (cases, expected) |value, want| {
        var argument: [32]u8 = undefined;
        const cli_arg = try std.fmt.bufPrint(&argument, "--value={s}", .{value});
        var results = try parseArgs(parser, std.testing.allocator, &.{cli_arg});
        defer deinitParsed(&results, std.testing.allocator);
        try std.testing.expectEqual(want, results.getFlag("value").?.parsed.boolean);
    }
}

test "parser reports invalid and missing flag values" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .long = "number", .description = "", .type = .{ .int = .{} } }},
    };
    try std.testing.expectError(error.IncompatibleType, parseArgs(parser, std.testing.allocator, &.{"--number=bad"}));
    try std.testing.expectError(error.MissingValue, parseArgs(parser, std.testing.allocator, &.{"--number"}));
    try std.testing.expectError(error.UnknownFlag, parseArgs(parser, std.testing.allocator, &.{"--missing"}));
}

test "short and long aliases refer to the same flag" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .short = 'v', .long = "verbose", .description = "", .type = .{ .boolean = .{} } }},
    };
    var short = try parseArgs(parser, std.testing.allocator, &.{"-v"});
    defer deinitParsed(&short, std.testing.allocator);
    try std.testing.expect(short.getFlag("verbose").?.parsed.boolean);
    try std.testing.expect(short.getFlag("v").?.parsed.boolean);
}

test "array flags append each occurrence" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .long = "tag", .description = "", .type = .{ .array = .{ .child = .string } } }},
    };
    var results = try parseArgs(parser, std.testing.allocator, &.{ "--tag", "one", "--tag=two" });
    defer deinitParsed(&results, std.testing.allocator);
    const values = &results.getFlag("tag").?.parsed.array.string;
    try std.testing.expectEqual(@as(usize, 1), values.items.len);
    try std.testing.expectEqualStrings("one", values.items[0]);
}

test "array flags report missing and invalid values" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .long = "number", .description = "", .type = .{ .array = .{ .child = .int } } }},
    };
    try std.testing.expectError(error.MissingValue, parseArgs(parser, std.testing.allocator, &.{"--number"}));
    try std.testing.expectError(error.IncompatibleType, parseArgs(parser, std.testing.allocator, &.{ "--number", "bad" }));
}

test "unknown flags can be skipped" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .long = "known", .description = "", .type = .{ .boolean = .{} } }},
    };
    var results = try parser.parse(std.testing.allocator, &.{ "--unknown", "--known" }, .{ .stop_on_unknown = false });
    defer deinitParsed(&results, std.testing.allocator);
    try std.testing.expect(results.getFlag("known").?.parsed.boolean);
}

test "stop options control where parsing ends" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .long = "verbose", .description = "", .type = .{ .boolean = .{} } }},
        .positional_args = &.{.{ .name = "command", .description = "", .type = .{ .string = .{} } }},
    };
    var stopped = try parser.parse(std.testing.allocator, &.{ "--verbose", "run" }, .{ .parse_upto_first_positional = true });
    defer deinitParsed(&stopped, std.testing.allocator);
    try std.testing.expect(stopped.getFlag("verbose").?.parsed.boolean);
    try std.testing.expectEqual(@as(usize, 1), stopped.last_parsed);

    var at_word = try parser.parse(std.testing.allocator, &.{ "--verbose", "--stop", "run" }, .{ .stop_at = "--stop" });
    defer deinitParsed(&at_word, std.testing.allocator);
    try std.testing.expect(at_word.getFlag("verbose").?.parsed.boolean);
    try std.testing.expectEqual(@as(usize, 1), at_word.last_parsed);
}

test "explicit invalid boolean values are rejected" {
    const parser: zflag.Parser = .{
        .flags = &.{.{ .long = "enabled", .description = "", .type = .{ .boolean = .{} } }},
    };
    try std.testing.expectError(error.IncompatibleType, parseArgs(parser, std.testing.allocator, &.{"--enabled=maybe"}));
}

test "positional arrays collect values" {
    const parser: zflag.Parser = .{
        .positional_args = &.{.{ .name = "values", .description = "", .type = .{ .array = .{ .child = .uint } } }},
    };
    var results = try parseArgs(parser, std.testing.allocator, &.{ "1", "2", "3" });
    defer deinitParsed(&results, std.testing.allocator);
    const values = &results.getArg("values").?.parsed.array.uint;
    try std.testing.expectEqual(@as(usize, 3), values.items.len);
    try std.testing.expectEqual(@as(u64, 1), values.items[0]);
    try std.testing.expectEqual(@as(u64, 3), values.items[2]);
}

test "parseStruct maps fields and defaults" {
    const Config = struct {
        count: i64 = 4,
        name: []const u8 = "default",
        enabled: bool = false,
    };
    const config = try zflag.parseStruct(Config, std.testing.allocator, &.{ "--count", "9", "--enabled" }, .{});
    try std.testing.expectEqual(@as(i64, 9), config.count);
    try std.testing.expectEqualStrings("default", config.name);
    try std.testing.expect(config.enabled);
}

test "fromStruct creates dotted names for nested fields" {
    const Config = struct {
        server: struct {
            port: u64 = 8080,
        } = .{},
    };
    const parser = zflag.fromStruct(Config);
    try std.testing.expectEqual(@as(usize, 1), parser.flags.len);
    try std.testing.expectEqualStrings("server.port", parser.flags[0].long);
}

test "help output includes usage, types, defaults, and descriptions" {
    const parser: zflag.Parser = .{
        .flags = &.{.{
            .short = 'v',
            .long = "verbose",
            .description = "Enable verbose output",
            .type = .{ .boolean = .{ .default = false } },
        }},
        .positional_args = &.{.{ .name = "file", .description = "Input file", .type = .{ .string = .{} } }},
    };
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try parser.putHelp(.{ .prog = "tool", .brief = "Brief", .description = "Details" }, &writer);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage: tool [OPTIONS]... file") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "POSITIONAL ARGS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "OPTIONS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-v --verbose (boolean)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Enable verbose output") != null);
}

test "positional arguments parse in declaration order" {
    const parser: zflag.Parser = .{
        .positional_args = &.{
            .{ .name = "count", .description = "", .type = .{ .uint = .{} } },
            .{ .name = "name", .description = "", .type = .{ .string = .{} } },
        },
    };
    var results = try parseArgs(parser, std.testing.allocator, &.{ "12", "Ada" });
    defer deinitParsed(&results, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 12), results.getArg("count").?.parsed.uint);
    try std.testing.expectEqualStrings("Ada", results.getArg("name").?.parsed.string);
    try std.testing.expectEqual(@as(usize, 2), results.last_parsed);
}
