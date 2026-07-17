const std = @import("std");
const Io = std.Io;

pub const ConverterErrors = std.mem.Allocator.Error || error{FailedToConvert};
pub const Converter = *const fn (context: *anyopaque, allocator: std.mem.Allocator, input: []const u8) ConverterErrors!*anyopaque;

pub const Converters = struct {
    pub fn Enum(comptime enum_type: type) Converter {
        return struct {
            pub fn func(
                _: *anyopaque,
                allocator: std.mem.Allocator,
                input: []const u8,
            ) ConverterErrors!*anyopaque {
                const mem = try allocator.create(enum_type);
                mem.* = std.meta.stringToEnum(enum_type, input) //
                    orelse return ConverterErrors.FailedToConvert;
                return mem;
            }
        }.func;
    }
};

pub fn SharedTypeOptions(comptime T: type) type {
    return struct {
        default: ?T = null,
    };
}

pub const SingleTypesTag = enum {
    int32,
    int64,
    uint32,
    uint64,
    float32,
    float64,
    string,
    boolean,
    custom,
};

pub const SingleTypes = union(SingleTypesTag) {
    int32: SharedTypeOptions(i32),
    int64: SharedTypeOptions(i64),
    uint32: SharedTypeOptions(u32),
    uint64: SharedTypeOptions(u64),
    float32: SharedTypeOptions(f32),
    float64: SharedTypeOptions(f64),
    string: SharedTypeOptions([]const u8),
    boolean: SharedTypeOptions(bool),
    custom: struct {
        converter: Converter,
        // Uses in help
        type_name: []const u8,
        // Uses in help
        possible_values: []const []const u8 = &.{},
        options: SharedTypeOptions([]const u8),
    },

    pub fn fromEnum(
        comptime enum_type: type,
        options: SharedTypeOptions(enum_type),
    ) SingleTypes {
        var updated_options: SharedTypeOptions([]const u8) = undefined;
        const fields = std.meta.fields(SharedTypeOptions(enum_type));

        inline for (fields) |field| {
            const name = field.name;
            comptime if (!std.mem.eql(u8, name, "default")) {
                @field(updated_options, name) = @field(options, name);
            };
        }

        if (options.default) |default_val| {
            updated_options.default = @tagName(default_val);
        } else {
            updated_options.default = null;
        }
        var splitter = std.mem.splitBackwardsScalar(u8, @typeName(enum_type), '.');
        return .{ .custom = .{
            .converter = Converters.Enum(enum_type),
            .possible_values = std.meta.fieldNames(enum_type),
            .type_name = splitter.first(),
            .options = updated_options,
        } };
    }
};

pub const ChildTypes = union(SingleTypesTag) {
    int32: void,
    int64: void,
    uint32: void,
    uint64: void,
    float32: void,
    float64: void,
    string: void,
    boolean: void,
    custom: struct {
        converter: Converter,
        // Uses in help
        type_name: []const u8,
        // Uses in help
        possible_values: []const []const u8 = &.{},
    },

    pub fn fromEnum(
        comptime enum_type: type,
    ) ChildTypes {
        var splitter = std.mem.splitBackwardsScalar(u8, @typeName(enum_type), '.');
        return .{ .custom = .{
            .converter = Converters.Enum(enum_type),
            .possible_values = std.meta.fieldNames(enum_type),
            .type_name = splitter.first(),
        } };
    }
};

pub const ObjectField = struct {
    name: []const u8,
    description: []const u8,
    type: SupportedType,
};

const UnionField = struct {
    name: []const u8,
    description: []const u8,
    type: SupportedType,
};

pub const MultiTypes = union(enum) {
    array: ArrayType,
    object: ObjectType,
    unionn: UnionType,

    pub const ArrayType = struct {
        child: ChildTypes,
        allow_empty: bool = false,
    };
    pub const ObjectType =
        struct {
            fields: []const ObjectField,
        };
    pub const UnionType =
        struct {
            fields: []const UnionField,
            // If you want default for union, exclude the default field
            // from .fields and put it here, it will get concat when parse
            // and print help
            default: ?*const ObjectField = null,
        };
};

pub const SupportedType = union(enum) {
    single: SingleTypes,
    multi: MultiTypes,
};

pub const Flag = struct {
    short: u8,
    long: []const u8,
    description: []const u8,
    type: SupportedType,
};

pub const Arg = struct {
    name: []const u8,
    description: []const u8,
    type: SupportedType,
};

pub const HelpFlag: Flag = .{
    .short = 'h',
    .long = "help",
    .description = "Show help and quit",
    .type = .{ .single = .{ .boolean = .{ .default = false } } },
};

const indent = " " ** 4;
pub const Parser = struct {
    terminal_width: u32 = 80,
    prog: []const u8,
    brief: []const u8,
    description: []const u8,
    parse_options: ParseOptions,

    flags: []const Flag = &.{},
    positional_args: []const Arg = &.{},

    const ParseOptions = struct {
        case_sensitive: bool = true,
        separator: []const u8 = ".",
        // Enable this to support sub commands
        parse_til_last_positional: bool = false,
    };

    pub fn parse(self: Parser, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn putHelp(self: Parser, writer: *Io.Writer) !void {
        // brief and desc
        if (self.brief.len > 0) {
            try writer.print("{s}\n", .{self.brief});
        }
        if (self.description.len > 0) {
            try writer.print("\n{s}\n\n", .{self.description});
        }

        // usage
        try writer.print("Usage: {s} ", .{self.prog});
        if (self.flags.len > 0) {
            try writer.print("[OPTIONS]... ", .{});
        }
        for (self.positional_args, 0..) |arg, i| {
            if (i > 0) try writer.print(" ", .{});
            try printArgName(arg.type, arg.name, writer);
        }
        try writer.print("\n", .{});

        // positional
        if (self.positional_args.len > 0) {
            try writer.print("\nPOSITIONAL ARGS:\n", .{});
        }
        for (self.positional_args) |arg| {
            try printArg(arg.name, arg.description, arg.type, 1, writer);
        }

        // flags
        if (self.flags.len > 0) {
            try writer.print("\nOPTIONS:\n", .{});
        }
        for (self.flags) |flag| {
            try writer.print(indent ** 1, .{});
            try printFlagName(flag.type, flag.short, flag.long, writer);
            try writer.print(" (", .{});
            try printTypeName(flag.type, writer);
            try writer.print(")", .{});

            try printDefault(flag.type, writer);
            try writer.print("\n", .{});
            try writer.print(indent ** 2 ++ "{s}\n", .{flag.description});

            if (flag.type == .multi) {
                try printMultiTypeFields(flag.type.multi, 2, writer);
            }
        }
        try writer.flush();
    }
};

fn isOptional(ttype: SupportedType) bool {
    return switch (ttype) {
        .single => |t| switch (t) {
            .custom => |c| c.options.default != null,
            inline else => |c| c.default != null,
        },
        .multi => |t| switch (t) {
            .array => |a| a.allow_empty,
            .object => |o| blk: {
                for (o.fields) |field| {
                    if (!isOptional(field.type)) {
                        break :blk false;
                    }
                }
                break :blk true;
            }, // Has to check if all fields are optional, then it is optional
            .unionn => |u| u.default != null,
        },
    };
}

fn printArgName(arg_type: SupportedType, arg_name: []const u8, writer: *std.Io.Writer) !void {
    if (isOptional(arg_type)) {
        if (arg_type == .multi and arg_type.multi == .array) {
            try writer.print("[{s}...]", .{arg_name});
        } else {
            try writer.print("[{s}]", .{arg_name});
        }
    } else {
        if (arg_type == .multi and arg_type.multi == .array) {
            try writer.print("{s}...", .{arg_name});
        } else {
            try writer.print("{s}", .{arg_name});
        }
    }
}

fn printFlagName(arg_type: SupportedType, flag_short: u8, flag_long: []const u8, writer: *std.Io.Writer) !void {
    if (arg_type == .multi and arg_type.multi == .array) {
        try writer.print("-{c} --{s}...", .{ flag_short, flag_long });
    } else {
        try writer.print("-{c} --{s}", .{ flag_short, flag_long });
    }
}

fn printTypeName(arg_type: SupportedType, writer: *std.Io.Writer) Io.Writer.Error!void {
    switch (arg_type) {
        .single => |s| switch (s) {
            .custom => |c| if (c.possible_values.len == 0) {
                try writer.print("{s}", .{c.type_name});
            } else {
                for (c.possible_values, 0..) |value, i| {
                    if (i != 0) {
                        try writer.print("|", .{});
                    }
                    try writer.print("{s}", .{value});
                }
            },
            inline else => |_, tag| try writer.print(@tagName(tag), .{}),
        },
        .multi => |m| switch (m) {
            .array => |arr| {
                switch (arr.child) {
                    .custom => |value| {
                        try writer.print("(", .{});
                        try printTypeName(.{ .single = .{ .custom = .{
                            .converter = value.converter,
                            .options = .{ .default = null },
                            .type_name = value.type_name,
                            .possible_values = value.possible_values,
                        } } }, writer);
                        try writer.print(")", .{});
                    },
                    inline else => |_, tag| try printTypeName(
                        .{ .single = @unionInit(
                            SingleTypes,
                            @tagName(tag),
                            .{ .default = null },
                        ) },
                        writer,
                    ),
                }
                try writer.print("[]", .{});
            },
            .object => try writer.print("Object", .{}),
            .unionn => try writer.print("Union", .{}),
        },
    }
}

fn printIndent(level: u8, writer: *std.Io.Writer) !void {
    for (0..level) |_| {
        try writer.print(indent, .{});
    }
}

fn printArg(
    arg_name: []const u8,
    arg_desc: []const u8,
    arg_type: SupportedType,
    indent_level: u8,
    writer: *std.Io.Writer,
) Io.Writer.Error!void {
    try printIndent(indent_level, writer);
    try printArgName(arg_type, arg_name, writer);
    try writer.print(" (", .{});
    try printTypeName(arg_type, writer);
    try writer.print(")", .{});
    try printDefault(arg_type, writer);
    try writer.print("\n", .{});

    try printIndent(indent_level + 1, writer);
    try writer.print("{s}\n", .{arg_desc});

    if (arg_type == .multi) {
        // try writer.print("\n", .{});
        try printMultiTypeFields(arg_type.multi, indent_level + 1, writer);
    }
}

fn printFlag(
    arg_name: []const u8,
    arg_desc: []const u8,
    arg_type: SupportedType,
    indent_level: u8,
    writer: *std.Io.Writer,
) Io.Writer.Error!void {
    try printIndent(indent_level, writer);
    try printArgName(arg_type, arg_name, writer);
    try writer.print(" (", .{});
    try printTypeName(arg_type, writer);
    try writer.print(")", .{});
    try printDefault(arg_type, writer);
    try writer.print("\n", .{});

    try printIndent(indent_level + 1, writer);
    try writer.print("{s}\n", .{arg_desc});

    if (arg_type == .multi) {
        try writer.print("\n", .{});
        try printMultiTypeFields(arg_type.multi, indent_level + 1, writer);
    }
}

fn printMultiTypeFields(
    multi_type: MultiTypes,
    indent_level: u8,
    writer: *std.Io.Writer,
) Io.Writer.Error!void {
    switch (multi_type) {
        .array => {},
        .object => |obj| {
            for (obj.fields) |field| {
                try printArg(field.name, field.description, field.type, indent_level, writer);
            }
        },
        .unionn => |uni| {
            if (uni.default) |default| {
                try printArg(default.name, default.description, default.type, indent_level, writer);
            }
            for (uni.fields) |field| {
                try printArg(field.name, field.description, field.type, indent_level, writer);
            }
        },
    }
}

fn printDefaultInner(arg_type: SupportedType, writer: *std.Io.Writer) Io.Writer.Error!void {
    switch (arg_type) {
        .single => |s| switch (s) {
            .custom => |c| try writer.print("{s}", .{c.options.default.?}),
            .string => |str| try writer.print("{s}", .{str.default.?}),
            inline else => |trivial| try writer.print("{}", .{trivial.default.?}),
        },
        .multi => |m| switch (m) {
            .array => try writer.print("[]", .{}),
            .object => {},
            .unionn => |u| {
                try writer.print("{s} = {{", .{u.default.?.name});
                try printDefaultInner(u.default.?.type, writer);
                try writer.print("}}", .{});
            },
        },
    }
}

fn printDefault(arg_type: SupportedType, writer: *std.Io.Writer) Io.Writer.Error!void {
    if (isOptional(arg_type)) {
        try writer.print(" Default: ", .{});

        try printDefaultInner(arg_type, writer);
    }
}

test {
    const Mode = enum { Read, Write };
    const Command = enum { here, there };
    const tmp: Parser = .{
        .prog = "mkdir",
        .brief = "Create the DIRECTORY(ies), if they do not already exist.",
        .description = "",
        .parse_options = .{ .parse_til_last_positional = true },
        .positional_args = &.{
            Arg{
                .name = "command",
                .description = "Command to run",
                .type = .{ .single = .fromEnum(Command, .{ .default = .here }) },
            },
            Arg{
                .name = "directory",
                .description = "Directory to create",
                .type = .{ .multi = .{ .array = .{ .child = .string } } },
            },
        },
        .flags = &.{ HelpFlag, Flag{
            .short = 'm',
            .long = "mode",
            .description = "set file mode",
            .type = .{ .multi = .{ .array = .{ .child = .fromEnum(Mode) } } },
        }, Flag{
            .short = 'p',
            .long = "parents",
            .description = "no error if existing, make parent directories as needed",
            .type = .{ .single = .{ .boolean = .{ .default = false } } },
        }, Flag{
            .short = 's',
            .long = "struct",
            .description = "Test struct",
            .type = .{ .multi = .{ .object = .{ .fields = &.{
                ObjectField{
                    .name = "int",
                    .description = "Int32 field",
                    .type = .{ .single = .{ .int32 = .{} } },
                },
                ObjectField{
                    .name = "float",
                    .description = "Float32 field",
                    .type = .{ .single = .{ .float32 = .{} } },
                },
                ObjectField{
                    .name = "string",
                    .description = "String field",
                    .type = .{ .single = .{ .string = .{} } },
                },
                ObjectField{
                    .name = "array",
                    .description = "Array field",
                    .type = .{ .multi = .{ .array = .{ .child = .int32 } } },
                },
                ObjectField{
                    .name = "union",
                    .description = "Union field",
                    .type = .{ .multi = .{
                        .unionn = .{
                            .fields = &.{
                                UnionField{
                                    .name = "float",
                                    .description = "Float32 union field",
                                    .type = .{ .single = .{ .float32 = .{} } },
                                },
                                UnionField{
                                    .name = "int",
                                    .description = "Int32 union field",
                                    .type = .{ .single = .{ .float32 = .{} } },
                                },
                            },
                            .default = &ObjectField{
                                .name = "string",
                                .description = "String union field",
                                .type = .{ .single = .{ .string = .{ .default = "union" } } },
                            },
                        },
                    } },
                },
            } } } },
        }, Flag{
            .short = 'u',
            .long = "union",
            .description = "Union field",
            .type = .{ .multi = .{
                .unionn = .{
                    .fields = &.{
                        UnionField{
                            .name = "float",
                            .description = "Float32 union field",
                            .type = .{ .single = .{ .float32 = .{} } },
                        },
                        UnionField{
                            .name = "int",
                            .description = "Int32 union field",
                            .type = .{ .single = .{ .int32 = .{} } },
                        },
                    },
                    .default = &ObjectField{
                        .name = "string",
                        .description = "String union field",
                        .type = .{ .single = .{ .string = .{ .default = "union" } } },
                    },
                },
            } },
        } },
    };
    var buf: [512]u8 = undefined;
    const stderr = std.Io.File.stderr();
    var stderr_writer = stderr.writer(std.testing.io, &buf);
    try tmp.putHelp(&stderr_writer.interface);
}
