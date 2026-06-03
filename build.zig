const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // v0.6: optional libpiper FFI. Default OFF so casual users don't need the
    // libpiper.dylib + onnxruntime sidekicks just to use the `say` backend.
    // Build vendor/piper1-gpl/libpiper first, then pass -Dwith-piper=true.
    const with_piper = b.option(bool, "with-piper", "Link libpiper FFI (requires vendor build, see vendor/README.md)") orelse false;

    const piper_opts = b.addOptions();
    piper_opts.addOption(bool, "enabled", with_piper);

    const mod = b.addModule("agent_tts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "agent-tts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent_tts", .module = mod },
                .{ .name = "build_options", .module = piper_opts.createModule() },
            },
        }),
    });

    if (with_piper) {
        const libpiper_root = b.path("vendor/piper1-gpl/libpiper");
        const libpiper_dist_lib = b.path("vendor/piper1-gpl/libpiper/dist/lib");

        exe.root_module.addIncludePath(libpiper_root.path(b, "include"));
        exe.root_module.addLibraryPath(libpiper_dist_lib);
        // linkSystemLibrary("c++") auto-flips link_libcpp which also pulls libc.
        exe.root_module.linkSystemLibrary("piper", .{});
        exe.root_module.linkSystemLibrary("c++", .{});
        // libpiper.dylib pulls in libonnxruntime.1.22.0.dylib at runtime via
        // @rpath. The rpath fix below points the binary at dist/lib where both
        // dylibs live.

        // Resolve @rpath at runtime to the vendored dist/lib dir. Absolute path
        // so the binary works from any cwd during dev. v1.0 ship plan will use
        // a relative @loader_path so brew tap can relocate.
        const abs_lib_path = libpiper_dist_lib.getPath(b);
        exe.root_module.addRPath(.{ .cwd_relative = abs_lib_path });
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
