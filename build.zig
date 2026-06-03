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
            // v0.3: SQLite WAL queue persists in ~/.cache/agent-tts/queue.db.
            // macOS ships libsqlite3 in the SDK sysroot; @cImport in queue.zig
            // pulls sqlite3.h from the same place. link_libc required for the
            // C header to resolve typedefs (size_t, etc).
            .link_libc = true,
            .imports = &.{
                .{ .name = "agent_tts", .module = mod },
                .{ .name = "build_options", .module = piper_opts.createModule() },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("sqlite3", .{});

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

    // Dedicated test target for the preprocessor (v0.5). Zig's addTest
    // only collects tests from the file you point it to, not from its
    // imports — so each test-bearing file gets its own step.
    const preproc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/preproc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_preproc_tests = b.addRunArtifact(preproc_tests);

    // Benchmark executable for the preprocessor (used to populate
    // _qa/v0.5-baseline.md). Build in ReleaseFast for realistic numbers.
    const preproc_mod = b.createModule(.{
        .root_source_file = b.path("src/preproc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench-preproc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/bench_preproc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "preproc", .module = preproc_mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench-preproc", "Run preproc benchmark");
    bench_step.dependOn(&run_bench.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_preproc_tests.step);
}
