const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zflag = b.addModule("flagz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zflag_test = b.addModule("zfag_test", .{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
    });

    zflag_test.addImport("zflag", zflag);
    const mod_tests = b.addTest(.{
        .root_module = zflag_test,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const format_step = b.step("fmt", "Format the project");
    format_step.dependOn(&b.addFmt(.{
        .paths = &.{ "src/", "build.zig" },
        .check = true,
    }).step);
}
