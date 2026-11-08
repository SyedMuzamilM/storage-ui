const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Use macOS and Metal") orelse true;
    const exe = b.addExecutable(.{
        .name = "storage-ui",
        .root_module = browserModule(b, "src/main.zig", target, optimize, native),
    });
    if (native) exe.root_module.linkFramework("Security", .{});
    b.installArtifact(exe);

    if (native) {
        const bundle = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "Storage.app/Contents/MacOS" } },
            .dest_sub_path = "Storage",
        });
        b.getInstallStep().dependOn(&bundle.step);
        b.installFile("resources/Info.plist", "Storage.app/Contents/Info.plist");
    }

    const run = b.addRunArtifact(exe);
    if (b.option([]const u8, "screenshot", "Capture the native window to PNG")) |path| {
        run.addArgs(&.{
            "--screenshot",
            path,
            b.option([]const u8, "scene", "Screenshot scene") orelse "browser",
        });
    }
    if (b.option(bool, "demo", "Open the in-memory demo") orelse false) run.addArg("--demo");
    b.step("run", "Open Storage").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = browserModule(b, "src/tests.zig", target, optimize, false),
    });
    b.step("test", "Run storage and UI behavior tests").dependOn(&b.addRunArtifact(tests).step);

    const integration = b.addExecutable(.{
        .name = "storage-s3-integration",
        .root_module = browserModule(b, "src/integration.zig", target, optimize, false),
    });
    const integration_run = b.addRunArtifact(integration);
    integration_run.addArgs(&.{
        b.option([]const u8, "endpoint", "Local S3 test fixture endpoint") orelse "http://127.0.0.1:9000",
        b.option([]const u8, "fixture-dir", "S3 fixture temporary directory") orelse "/tmp/storage-s3-test",
    });
    b.step("test-s3", "Exercise signed S3 operations against a local fixture").dependOn(&integration_run.step);

    if (native) {
        const journey = b.addExecutable(.{
            .name = "storage-native-journey",
            .root_module = browserModule(b, "src/native_journey.zig", target, optimize, true),
        });
        b.step("test-native", "Verify AppKit drops and capture native UI journeys").dependOn(&b.addRunArtifact(journey).step);
    }
}

fn browserModule(
    b: *std.Build,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    native: bool,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "zircon_ui",
                .module = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize, .native = native }).module("zircon_ui"),
            },
            .{
                .name = "zircon_editor",
                .module = b.dependency("zircon_editor", .{ .target = target, .optimize = optimize, .native = native }).module("zircon_editor"),
            },
            .{
                .name = "zircon_text",
                .module = b.dependency("zircon_text", .{ .target = target, .optimize = optimize }).module("zircon_text"),
            },
        },
    });
    module.linkSystemLibrary("curl", .{});
    return module;
}
