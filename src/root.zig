const std = @import("std");
const Io = std.Io;
pub const Parser = @This();
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

const cli_infos_name = "flagz_cli_infos";
const CliInfosType = std.StaticStringMap(CliInfo);
pub const CliInfo = struct {
    kind: Kind,
    desc: []const u8,

    const Kind = union(enum) {
        Flag: struct { short: ?u8 = null },
        Arg: void,
    };
};

const MAX_PREFIX_LEN = 512;
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

    pub fn getArg(self: ParsedResults, name: []const u8) ?ParsedItem {
        if (self.args.get(name)) |index| {
            return self.backing_storage[index];
        }
        return null;
    }
    pub fn getFlag(self: ParsedResults, name: []const u8) ?ParsedItem {
        if (self.flags.get(name)) |index| {
            return self.backing_storage[index];
        }
        return null;
    }

    pub fn deinit(self: *ParsedResults, allocator: std.mem.Allocator, option: struct { free_arrays: bool }) void {
        if (option.free_arrays) {
            for (self.backing_storage) |*storage| {
                switch (storage.parsed) {
                    .array => |*v| switch (v.*) {
                        inline else => |*vv| vv.deinit(allocator),
                    },
                    else => {},
                }
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
        .backing_storage = try allocator.alloc(ParsedItem, self.flags.len + self.positional_args.len),
        .args = .empty,
        .flags = .empty,
        .last_parsed = cli_args.len,
    };
    // Make sure the array list can be properly clean up
    for (result.backing_storage) |*item| {
        item.* = .{ .user_input = false, .parsed = .{ .boolean = false } };
    }
    errdefer result.deinit(allocator, .{ .free_arrays = true });
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
                const flag = self.flags[ii - self.positional_args.len];
                switch (flag.type) {
                    .array => {},
                    inline else => |_, tag| result.backing_storage[ii] = .{
                        .user_input = true,
                        .parsed = try convert(std.meta.stringToEnum(
                            PrimitiveTypes,
                            @tagName(tag),
                        ).?, value),
                    },
                }
            } else {
                const ii = result.flags.get(trimmed) orelse {
                    if (parse_options.stop_on_unknown) {
                        return ParseError.UnknownFlag;
                    }
                    continue;
                };
                const flag = self.flags[ii - self.positional_args.len];
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
                                try v.append(allocator, @field(
                                    try convert(tag, next),
                                    @tagName(tag),
                                ));
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
                            .parsed = try convert(
                                std.meta.stringToEnum(
                                    PrimitiveTypes,
                                    @tagName(tag),
                                ).?,
                                next,
                            ),
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

/// Add short and descriptions to `const flagz_cli_info = .{ ... };`
pub fn fromStruct(comptime Struct: type) Parser {
    const Storage = struct {
        const tmp = fromStructComptime(Struct);
    };
    const parser: Parser = .{
        .flags = &Storage.tmp.flags,
        .positional_args = &Storage.tmp.args,
    };

    return parser;
}

fn fromStructComptime(comptime Struct: type) struct {
    flags: [count(Struct).num_flags]Flag,
    args: [count(Struct).num_args]Arg,
} {
    const counts = count(Struct);
    comptime var _args: [counts.num_args]Arg = undefined;
    comptime var _flags: [counts.num_flags]Flag = undefined;
    _fromStruct(Struct, "", &_args, &_flags);
    return .{ .args = _args, .flags = _flags };
}

pub fn parseStruct(
    comptime Struct: type,
    allocator: std.mem.Allocator,
    cli_args: []const []const u8,
    parse_options: ParseOptions,
) ParseError!Struct {
    const Storage = struct {
        const tmp = fromStructComptime(Struct);
    };
    const parser: Parser = .{
        .flags = &Storage.tmp.flags,
        .positional_args = &Storage.tmp.args,
    };
    var parsed = try parser.parse(allocator, cli_args, parse_options);
    defer parsed.deinit(allocator, .{ .free_arrays = false });
    var result: Struct = undefined;
    try populateStruct(Struct, &result, &parsed, allocator, "");
    return result;
}

fn populateStruct(
    comptime Struct: type,
    result: *Struct,
    parsed: *ParsedResults,
    allocator: std.mem.Allocator,
    comptime prefix: []const u8,
) ParseError!void {
    const cli_infos = getCliInfos(Struct);

    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .@"struct") {
            try populateStruct(
                field.type,
                &@field(result.*, field.name),
                parsed,
                allocator,
                prefix ++ field.name ++ ".",
            );
            continue;
        }

        const name = prefix ++ field.name;
        const item = if (cli_infos.get(field.name)) |info|
            switch (info.kind) {
                .Arg => parsed.getArg(name).?,
                .Flag => parsed.getFlag(name).?,
            }
        else
            parsed.getFlag(name).?;
        const expected_type = comptime typeToTypes(field.type, null);

        switch (expected_type) {
            .array => |arr| {
                var array_list = &@field(item.parsed.array, @tagName(arr.child));
                @field(result.*, field.name) = try array_list.toOwnedSlice(allocator);
            },
            inline else => |_, tag| {
                @field(result.*, field.name) = @field(item.parsed, @tagName(tag));
            },
        }
    }
}

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
    if (self.flags.len > 0) {
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

fn _fromStruct(
    comptime Struct: type,
    comptime prefix: []const u8,
    comptime args_slot: *[count(Struct).num_args]Arg,
    comptime flags_slot: *[count(Struct).num_flags]Flag,
) void {
    const cli_infos = getCliInfos(Struct);
    const type_info = @typeInfo(Struct).@"struct";
    var arg_counter = 0;
    var flag_counter = 0;

    for (type_info.fields) |field| {
        const cli_info = cli_infos.get(field.name);
        if (@typeInfo(field.type) == .@"struct") {
            const counts = count(field.type);
            _fromStruct(
                field.type,
                prefix ++ field.name ++ ".",
                args_slot[arg_counter .. arg_counter + counts.num_args],
                flags_slot[flag_counter .. flag_counter + counts.num_flags],
            );
            arg_counter += counts.num_args;
            flag_counter += counts.num_flags;
            continue;
        }
        // Normal field
        if (cli_info) |info| {
            switch (info.kind) {
                .Arg => {
                    args_slot[arg_counter] = Arg{
                        .name = prefix ++ field.name,
                        .description = info.desc,
                        .type = typeToTypes(field.type, field.defaultValue()),
                    };
                    arg_counter += 1;
                },
                .Flag => |fff| {
                    flags_slot[flag_counter] = Flag{
                        .long = prefix ++ field.name,
                        .short = fff.short,
                        .description = info.desc,
                        .type = typeToTypes(field.type, field.defaultValue()),
                    };
                    flag_counter += 1;
                },
            }
        } else {
            // Flag
            flags_slot[flag_counter] = Flag{
                .long = prefix ++ field.name,
                .type = typeToTypes(field.type, field.defaultValue()),
                .description = "",
            };
            flag_counter += 1;
        }
    }
}

fn typeToTypes(comptime T: type, default: ?T) Types {
    return switch (T) {
        u64 => Types{ .uint = .{ .default = default } },
        i64 => Types{ .int = .{ .default = default } },
        f64 => Types{ .float = .{ .default = default } },
        bool => Types{ .boolean = .{ .default = default } },
        []const u8, []u8 => Types{ .string = .{ .default = default } },
        else => |TT| blk: {
            const info = @typeInfo(TT);
            switch (info) {
                .array => |arr| break :blk Types{ .array = .{
                    .child = std.meta.stringToEnum(
                        PrimitiveTypes,
                        @tagName(typeToTypes(arr.child, null)),
                    ),
                    .allow_empty = default != null,
                } },
                else => @compileError("Flagz does not support " ++ @typeName(TT)),
            }
        },
    };
}

fn getCliInfos(comptime Struct: type) CliInfosType {
    return comptime if (@hasDecl(Struct, cli_infos_name) //
    and @TypeOf(@field(Struct, cli_infos_name)) == CliInfosType)
        @field(Struct, cli_infos_name)
    else
        CliInfosType.initComptime(.{});
}

fn count(comptime Struct: type) struct {
    num_args: comptime_int,
    num_flags: comptime_int,
    max_stack: comptime_int,
} {
    const type_info = @typeInfo(Struct).@"struct";

    comptime var num_args = 0;
    comptime var num_flags = 0;
    comptime var max_stack = 1;

    const cli_infos = getCliInfos(Struct);

    for (type_info.fields) |field| {
        const cli_info = cli_infos.get(field.name);
        const is_struct = @typeInfo(field.type) == .@"struct";

        var is_arg = false;
        if (cli_info) |info| {
            if (info.kind == .Arg) {
                is_arg = true;
            }
        }

        if (is_struct and is_arg) {
            @compileError("Struct can not be in args, use string and json");
        }
        if (is_arg) {
            num_args += 1;
        } else if (!is_struct) {
            // If is struct then the struct will be multiple flags as struct fields
            // the struct as a whole is not a flag
            num_flags += 1;
        }

        if (is_struct) {
            const tmp = count(field.type);
            num_args += tmp.num_args;
            num_flags += tmp.num_flags;
            max_stack = @max(max_stack, tmp.max_stack + 1);
        }
    }
    return .{
        .max_stack = max_stack,
        .num_flags = num_flags,
        .num_args = num_args,
    };
}

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
    if (flag.short) |short| {
        try writer.print("-{c} --{s}", .{ short, flag.long });
    } else {
        try writer.print("     --{s}", .{flag.long});
    }
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
