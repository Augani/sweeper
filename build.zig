const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options - allows cross-compilation
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Option to skip GUI build (useful for CI where raylib takes too long)
    const build_gui = b.option(bool, "gui", "Build the GUI application (default: true)") orelse true;

    // Main executable (TUI/CLI only - no raylib dependency)
    const exe = b.addExecutable(.{
        .name = "sweeper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Platform-specific linking
    const target_info = target.query;
    if (target_info.os_tag) |os| {
        switch (os) {
            .windows => {
                exe.root_module.linkSystemLibrary("kernel32", .{});
                exe.root_module.linkSystemLibrary("shell32", .{});
            },
            else => {},
        }
    }

    // Install the executable
    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow passing arguments to the application
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Sweeper CLI tool");
    run_step.dependOn(&run_cmd.step);

    // GUI executable with raylib (optional)
    if (build_gui) {
        const raylib_dep = b.dependency("raylib_zig", .{
            .target = target,
            .optimize = optimize,
        });

        const gui_exe = b.addExecutable(.{
            .name = "sweeper-gui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui_main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        gui_exe.root_module.addImport("raylib", raylib_dep.module("raylib"));
        raylib_dep.module("raylib").linkLibrary(raylib_dep.artifact("raylib"));
        gui_exe.linkLibrary(raylib_dep.artifact("raylib"));

        // Platform-specific linking for GUI
        if (target_info.os_tag) |os| {
            switch (os) {
                .macos => {
                    gui_exe.root_module.linkFramework("Cocoa", .{});
                    gui_exe.root_module.linkFramework("IOKit", .{});
                    gui_exe.root_module.linkFramework("CoreFoundation", .{});
                    gui_exe.root_module.linkFramework("CoreGraphics", .{});
                    gui_exe.root_module.linkFramework("CoreVideo", .{});
                },
                .windows => {
                    gui_exe.root_module.linkSystemLibrary("kernel32", .{});
                    gui_exe.root_module.linkSystemLibrary("shell32", .{});
                    gui_exe.root_module.linkSystemLibrary("gdi32", .{});
                    gui_exe.root_module.linkSystemLibrary("user32", .{});
                    gui_exe.root_module.linkSystemLibrary("opengl32", .{});
                },
                .linux => {
                    gui_exe.root_module.linkSystemLibrary("GL", .{});
                    gui_exe.root_module.linkSystemLibrary("X11", .{});
                },
                else => {},
            }
        }

        b.installArtifact(gui_exe);

        // Run GUI step
        const run_gui_cmd = b.addRunArtifact(gui_exe);
        run_gui_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_gui_cmd.addArgs(args);
        }

        const run_gui_step = b.step("run-gui", "Run the desktop cleanup GUI");
        run_gui_step.dependOn(&run_gui_cmd.step);
    }

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
