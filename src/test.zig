const std = @import("std");
const Parser = @import("zflag");
const Arg = Parser.Arg;
const Flag = Parser.Flag;

test {
    const parser: Parser = .{
        .prog = "mkdir",
        .brief = "Create the DIRECTORY(ies), if they do not already exist.",
        .description = "",
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

    var buf: [512]u8 = undefined;
    const stderr = std.Io.File.stderr();
    var stderr_writer = stderr.writer(std.testing.io, &buf);
    try parser.putHelp(&stderr_writer.interface);
    var result = try parser.parse(std.testing.allocator, &.{ "a", "b", "c", "-p" }, .{});
    defer result.deinit(std.testing.allocator);
    const directories = result.getArgResult("directory").?.parsed.array.string;
    for (directories.items) |dir| {
        std.debug.print("{s}\n", .{dir});
    }
    const parent = result.getFlagResult("parents").?.parsed.boolean;
    std.debug.print("parent: {}\n", .{parent});
    // var args_iter = result.args.iterator();
    // while (args_iter.next()) |entry| {
    //     std.debug.print("{s} => {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    // }
}
