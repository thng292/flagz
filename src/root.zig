const std = @import("std");
const Io = std.Io;
const Parser = @This();
const logger = std.log.scoped(.Flagz);

pub fn SharedTypeOptions(comptime T: type) type {
    return struct {
        default: ?T = null,
    };
}

pub const PrimitiveTypes = enum { int, uint, float, string, boolean };

pub const TypesTag = enum { int, uint, float, string, boolean, array };
pub const Types = union(TypesTag) {
    int: SharedTypeOptions(i64),
    uint: SharedTypeOptions(u64),
    float: SharedTypeOptions(f64),
    string: SharedTypeOptions([]const u8),
    boolean: SharedTypeOptions(bool),
    array: struct {
        child: PrimitiveTypes,
        allow_empty: bool = false,
    },
};

pub const ParsedValue = union(TypesTag) {
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    boolean: bool,
    array: Array,

    pub const Array = union(PrimitiveTypes) {
        int: std.ArrayListUnmanaged(i64),
        uint: std.ArrayListUnmanaged(u64),
        float: std.ArrayListUnmanaged(f64),
        string: std.ArrayListUnmanaged([]const u8),
        boolean: std.ArrayListUnmanaged(bool),
    };
};

pub const Flag = struct {
    short: ?u8 = null,
    long: []const u8,
    description: []const u8,
    type: Types,
};

pub const Arg = struct {
    name: []const u8,
    description: []const u8,
    type: Types,
};

pub const HelpFlag: Flag = .{
    .short = 'h',
    .long = "help",
    .description = "Show help and quit",
    .type = .{ .boolean = .{ .default = false } },
};

pub const UnknownFlag: Flag = .{
    .description = "Unknown flag",
    .long = "unknown",
    .short = 0,
    .type = .{ .string = .{} },
};

const indent = " " ** 2;

flags: []const Flag = &.{},
positional_args: []const Arg = &.{},

const ParseOptions = struct {
    // Enable this to support sub commands
    parse_upto_first_positional: bool = false,
    stop_at: ?[]const u8 = null,
    stop_on_unknown: bool = true,
};

pub const ParsedItem = struct {
    user_input: bool,
    parsed: ParsedValue,
};

pub const ParsedResults = struct {
    backing_storage: []ParsedItem,
    flags: std.StringArrayHashMapUnmanaged(usize),
    args: std.StringArrayHashMapUnmanaged(usize),
    last_parsed: usize,

    pub fn getArgResult(self: ParsedResults, name: []const u8) ?ParsedItem {
        if (self.args.get(name)) |index| {
            return self.backing_storage[index];
        }
        return null;
    }

    pub fn getFlagResult(self: ParsedResults, name: []const u8) ?ParsedItem {
        if (self.flags.get(name)) |index| {
            return self.backing_storage[index];
        }
        return null;
    }

    pub fn deinit(self: *ParsedResults, allocator: std.mem.Allocator) void {
        for (self.backing_storage) |*storage| {
            switch (storage.parsed) {
                .array => |*v| switch (v.*) {
                    inline else => |*vv| vv.deinit(allocator),
                },
                else => {},
            }
        }
        allocator.free(self.backing_storage);
        self.args.deinit(allocator);
        self.flags.deinit(allocator);
    }
};

pub const ParseError = std.mem.Allocator.Error || error{
    UnknownFlag,
    UnexpectedNumberOfArg,
    IncompatibleType,
    MissingValue,
};

pub fn parse(
    self: Parser,
    allocator: std.mem.Allocator,
    cli_args: []const []const u8,
    parse_options: ParseOptions,
) ParseError!ParsedResults {
    var result: ParsedResults = .{
        .backing_storage = try allocator.alloc(
            ParsedItem,
            self.positional_args.len + self.flags.len,
        ),
        .args = .empty,
        .flags = .empty,
        .last_parsed = cli_args.len,
    };
    // Make sure the array list can be properly clean up
    for (result.backing_storage) |*item| {
        item.* = .{ .user_input = false, .parsed = .{ .boolean = false } };
    }
    errdefer result.deinit(allocator);
    // result.args.put(allocator, key: []const u8, value: u32)
    for (self.positional_args, 0..) |arg, i| {
        result.backing_storage[i] = .{
            .user_input = false,
            .parsed = defaultParsedValue(arg.type),
        };
        try result.args.put(allocator, arg.name, i);
    }
    for (self.flags, self.positional_args.len..) |*flag, i| {
        result.backing_storage[i] = .{
            .user_input = false,
            .parsed = defaultParsedValue(flag.type),
        };
        if (flag.short) |*short| {
            try result.flags.put(allocator, (short)[0..1], i);
        }
        try result.flags.put(allocator, flag.long, i);
    }

    // Parsing
    const State = struct {
        stop_word: []const u8,
        arg_count: u32 = 0,
        index: u32 = 0,
    };
    var state: State = .{
        .stop_word = parse_options.stop_at orelse "",
    };
    while (state.index < cli_args.len) : (state.index += 1) {
        const cli_arg = cli_args[state.index];

        if (std.mem.eql(u8, cli_arg, state.stop_word)) {
            std.log.debug("Hit the stop at: {s}", .{state.stop_word});
            break;
        }

        if (cli_arg[0] == '-') {
            // Flag
            const trimmed = std.mem.trimStart(u8, cli_arg, "-");
            const index_of_eql = std.mem.indexOfScalar(u8, trimmed, '=');
            if (index_of_eql) |index| {
                const flag_name = trimmed[0..index];
                const value = trimmed[index + 1 ..];
                const ii = result.flags.get(flag_name) orelse {
                    if (parse_options.stop_on_unknown) {
                        return ParseError.UnknownFlag;
                    }
                    continue;
                };
                const flag = self.flags[ii];
                switch (flag.type) {
                    .array => {},
                    inline else => |_, tag| result.backing_storage[ii] = .{
                        .user_input = true,
                        .parsed = try convert(std.meta.stringToEnum(PrimitiveTypes, @tagName(tag)).?, value),
                    },
                }
            } else {
                const ii = result.flags.get(trimmed) orelse {
                    if (parse_options.stop_on_unknown) {
                        return ParseError.UnknownFlag;
                    }
                    continue;
                };
                const flag = self.flags[ii];
                const storage = &result.backing_storage[ii];
                // Bool flag behavior is similar to golang's flag
                // https://pkg.go.dev/flag#hdr-Command_line_flag_syntax
                switch (flag.type) {
                    .boolean => storage.* = .{
                        .user_input = true,
                        .parsed = .{ .boolean = true },
                    },
                    .array => {
                        state.index += 1;
                        if (state.index >= cli_args.len) {
                            return ParseError.MissingValue;
                        }
                        const next = cli_args[state.index];
                        // Append shit here
                        storage.user_input = true;
                        switch (storage.parsed.array) {
                            inline else => |*v, tag| {
                                try v.append(allocator, @field(try convert(tag, next), @tagName(tag)));
                            },
                        }
                    },
                    inline else => |_, tag| {
                        state.index += 1;
                        if (state.index >= cli_args.len) {
                            return ParseError.MissingValue;
                        }
                        const next = cli_args[state.index];
                        // Append shit here
                        storage.* = .{
                            .user_input = true,
                            .parsed = try convert(std.meta.stringToEnum(PrimitiveTypes, @tagName(tag)).?, next),
                        };
                    },
                }
            }
        } else {
            // This is an Argument
            const arg = &self.positional_args[state.arg_count];
            const storage = &result.backing_storage[state.arg_count];
            switch (arg.type) {
                .array => {
                    storage.user_input = true;
                    switch (storage.parsed.array) {
                        inline else => |*v, tag| {
                            const converted = convert(tag, cli_arg);
                            if (converted) |cvt| {
                                try v.append(allocator, @field(cvt, @tagName(tag)));
                            } else |_| {
                                state.arg_count += 1;
                            }
                        },
                    }
                },
                inline else => |_, tag| {
                    storage.user_input = true;
                    storage.parsed = try convert(std.meta.stringToEnum(PrimitiveTypes, @tagName(tag)).?, cli_arg);
                    state.arg_count += 1;
                },
            }
            if (parse_options.parse_upto_first_positional) {
                break;
            }
        }
    }
    result.last_parsed = state.index;
    return result;
}

const Meta = struct {
    Struct: type,
    parser: Parser,

    pub const CliInfo = struct {
        kind: Kind,
        desc: []const u8,

        const Kind = union(enum) {
            flag: struct { short: ?u8 = null },
            arg: void,
        };
    };

    /// Convert struct to Parser
    /// Add short and descriptions to `const flagz_cli_info = .{ ... };`
    pub fn from(
        comptime Struct: type,
    ) Meta {
        const type_info = @typeInfo(Struct).@"struct";
        for (type_info.fields) |field| {
            field.defaultValue();
        }
        return .{ .Struct = Struct, .parser = .{} };
    }
};

const ProgramInfo = struct {
    prog: []const u8 = "",
    brief: []const u8 = "",
    description: []const u8 = "",
};

pub fn putHelp(self: Parser, info: ProgramInfo, writer: *Io.Writer) !void {

    // brief and desc
    if (info.brief.len > 0) {
        try writer.print("{s}\n", .{info.brief});
    }
    if (info.description.len > 0) {
        try writer.print("\n{s}\n\n", .{info.description});
    }

    // usage
    try writer.print("Usage: {s} ", .{info.prog});
    if (info.flags.len > 0) {
        try writer.print("[OPTIONS]... ", .{});
    }
    for (self.positional_args, 0..) |arg, i| {
        if (i > 0) try writer.print(" ", .{});
        try printArgName(arg, writer);
    }
    try writer.print("\n", .{});

    // Print positional args desc
    if (self.positional_args.len > 0) {
        try writer.print("\nPOSITIONAL ARGS:\n", .{});
    }
    for (self.positional_args) |arg| {
        try printArg(arg, writer);
    }

    // Print flag desc
    if (self.flags.len > 0) {
        try writer.print("\nOPTIONS:\n", .{});
    }
    for (self.flags) |flag| {
        try printFlag(flag, writer);
    }
    try writer.print("\n", .{});
    try writer.flush();
}

/// Handle parsing for both runtime and comptime
fn _parse() void {}

fn convert(ttype: PrimitiveTypes, value: []const u8) !ParsedValue {
    return switch (ttype) {
        .int => ParsedValue{ .int = std.fmt.parseInt(i64, value, 0) catch return ParseError.IncompatibleType },
        .uint => ParsedValue{ .uint = std.fmt.parseUnsigned(u64, value, 0) catch return ParseError.IncompatibleType },
        .float => ParsedValue{ .float = std.fmt.parseFloat(f64, value) catch return ParseError.IncompatibleType },
        .string => ParsedValue{ .string = value },
        .boolean => ParsedValue{ .boolean = parseBool(value) orelse return ParseError.IncompatibleType },
    };
}

fn parseBool(str: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(str, "true") or std.mem.eql(u8, str, "1")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(str, "false") or std.mem.eql(u8, str, "0")) {
        return false;
    }
    return null;
}

fn defaultParsedValue(ttype: Types) ParsedValue {
    return switch (ttype) {
        .int => |payload| ParsedValue{ .int = payload.default orelse 0 },
        .uint => |payload| ParsedValue{ .uint = payload.default orelse 0 },
        .float => |payload| ParsedValue{ .float = payload.default orelse 0 },
        .boolean => |payload| ParsedValue{ .boolean = payload.default orelse false },
        .string => |payload| ParsedValue{ .string = payload.default orelse "" },
        .array => |arr| switch (arr.child) {
            inline else => |tag| ParsedValue{
                .array = @unionInit(ParsedValue.Array, @tagName(tag), .empty),
            },
        },
    };
}

fn printArg(arg: Arg, writer: *Io.Writer) !void {
    try writer.print(indent, .{});
    try printArgName(arg, writer);
    try writer.print(" (", .{});
    try printTypeName(arg.type, writer);
    try writer.print(")", .{});
    try printDefault(arg.type, writer);
    try writer.print("\n", .{});
    try writer.print(indent ** 4 ++ "{s}\n", .{arg.description});
}

fn printFlag(flag: Flag, writer: *Io.Writer) !void {
    try writer.print(indent, .{});
    try writer.print("-{c} --{s}", .{ flag.short, flag.long });
    try writer.print(" (", .{});
    try printTypeName(flag.type, writer);
    try writer.print(")", .{});
    try printDefault(flag.type, writer);
    try writer.print("\n", .{});
    try writer.print(indent ** 4 ++ "{s}\n", .{flag.description});
}

fn printTypeName(ttype: Types, writer: *Io.Writer) !void {
    switch (ttype) {
        .array => |a| {
            try writer.print("{s}[]", .{@tagName(a.child)});
        },
        inline else => |_, tag| try writer.print(@tagName(tag), .{}),
    }
}

fn printDefault(ttype: Types, writer: *Io.Writer) !void {
    if (isOptional(ttype)) {
        try writer.print(" Default: ", .{});
        switch (ttype) {
            .array => try writer.print("[]", .{}),
            .string => |s| try writer.print("{?s}", .{s.default}),
            inline else => |t| try writer.print("{?}", .{t.default}),
        }
    }
}

fn printArgName(arg: Arg, writer: *std.Io.Writer) !void {
    if (arg.type == .array) {
        try writer.print("{s}...", .{arg.name});
    } else {
        try writer.print("{s}", .{arg.name});
    }
}

fn isOptional(ttype: Types) bool {
    return switch (ttype) {
        .array => |a| a.allow_empty,
        inline else => |t| t.default != null,
    };
}
