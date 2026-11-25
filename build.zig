const std = @import("std");
const raylib_build = @import("raylib_zig");

/// The layers, lowest first. Each is a build module rooted in its own folder,
/// so the compiler rejects an import that reaches outside it, and each module
/// is given only the modules below it:
///   core   src/core   rules, read models, save and journal codecs (pure)
///   shell  src/shell  files, tracing and diagnostics around the core
///   app    src/app    raylib window, drawing, audio and input
///   tools  src/tools  command-line programs built on the core
/// `zig build check-deps` checks the layering inside each folder as well.
const Layers = struct {
    core: *std.Build.Module,
    shell: *std.Build.Module,

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Layers {
        const core = b.createModule(.{
            .root_source_file = b.path("src/core/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        const shell = b.createModule(.{
            .root_source_file = b.path("src/shell/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core }},
        });
        return .{ .core = core, .shell = shell };
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag == .emscripten) return buildWeb(b, target, optimize);
    const rl = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .X11,
        .rmodels = false,
        .raudio = true,
    });
    if (target.result.os.tag == .linux) useVendoredX11(b, rl.artifact("raylib"));
    const layers = Layers.init(b, target, optimize);
    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "core", .module = layers.core },
        .{ .name = "shell", .module = layers.shell },
        .{ .name = "raylib", .module = rl.module("raylib") },
    };
    const game = b.addExecutable(.{
        .name = "archipelagist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = app_imports,
        }),
    });
    const install_game = installFor(b, target, game);
    const run = b.addRunArtifact(game);
    b.step("run", "Play Archipelagist").dependOn(&run.step);

    const core_only: []const std.Build.Module.Import = &.{.{ .name = "core", .module = layers.core }};
    const replay_module = b.createModule(.{
        .root_source_file = b.path("src/tools/replay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = core_only,
    });
    const replay = b.addExecutable(.{ .name = "archipelagist-replay", .root_module = replay_module });
    const install_replay = installFor(b, target, replay);
    linkNativeBin(b, target, &.{ install_game, install_replay });
    const run_replay = b.addRunArtifact(replay);
    run_replay.addPassthruArgs();
    b.step("replay", "Replay a command journal headlessly: zig build replay -- JOURNAL [--until N] [--verbose] [--save OUT.sav]").dependOn(&run_replay.step);

    const host = Layers.init(b, b.graph.host, .ReleaseSafe);
    const bake = b.addRunArtifact(b.addExecutable(.{
        .name = "bake-lanes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/bake_lanes.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "core", .module = host.core }},
        }),
    }));
    bake.setCwd(b.path("."));
    b.step("bake-lanes", "Regenerate src/core/ferry_lanes.zig from the geography").dependOn(&bake.step);

    const check_deps = b.addRunArtifact(b.addExecutable(.{
        .name = "check-deps",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/check_deps.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));
    check_deps.setCwd(b.path("."));
    check_deps.addArg("src");
    check_deps.has_side_effects = true;
    b.step("check-deps", "Check that every @import points down the layers").dependOn(&check_deps.step);

    const tests = b.step("test", "Check dependencies and run core, shell, tool and presentation tests");
    tests.dependOn(&check_deps.step);
    const tested = Layers.init(b, b.graph.host, optimize);
    const test_roots = [_]*std.Build.Module{
        tested.core,
        tested.shell,
        b.createModule(.{
            .root_source_file = b.path("src/tools/replay.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = tested.core }},
        }),
        b.createModule(.{
            .root_source_file = b.path("src/tools/check_deps.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
        b.createModule(.{
            .root_source_file = b.path("src/app/presentation_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = app_imports,
        }),
    };
    for (test_roots) |root| tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);

    const mutations = b.addSystemCommand(&.{"python3"});
    mutations.addFileArg(b.path("tools/mutation_test.py"));
    mutations.addArgs(&.{ "--zig", b.graph.zig_exe });
    // For example: zig build mutation-test -- --all --jobs 4, or --file ferry.zig.
    mutations.addPassthruArgs();
    b.step("mutation-test", "Generate mutants by operator and run the tests against them").dependOn(&mutations.step);
}

/// Every build installs to zig-out/<os>-<arch>/bin, such as
/// zig-out/macos-arm64/bin or zig-out/linux-x86_64/bin, so builds for
/// different machines sit side by side.
fn binDir(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        else => |arch| @tagName(arch),
    };
    return b.fmt("{s}-{s}/bin", .{ @tagName(target.result.os.tag), arch });
}

fn installFor(b: *std.Build, target: std.Build.ResolvedTarget, artifact: *std.Build.Step.Compile) *std.Build.Step {
    const install = b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = binDir(b, target) } } });
    b.getInstallStep().dependOn(&install.step);
    return &install.step;
}

/// For a native build, points zig-out/bin at this machine's folder, so
/// zig-out/bin/archipelagist is always the build you can run here.
fn linkNativeBin(b: *std.Build, target: std.Build.ResolvedTarget, installs: []const *std.Build.Step) void {
    if (!target.query.isNative() or b.graph.host.result.os.tag == .windows) return;
    const link = b.addRunArtifact(b.addExecutable(.{
        .name = "link-bin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/link_bin.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));
    link.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{});
    link.addArg(binDir(b, target));
    link.has_side_effects = true;
    for (installs) |install| link.step.dependOn(install);
    b.getInstallStep().dependOn(&link.step);
}

/// GLFW loads libX11, its extensions and libGL with dlopen when the game
/// starts, so raylib needs only their headers to build for Linux. (Install
/// those libraries on the Linux machine that runs the game; any X11 desktop
/// already has them.) Use the
/// copies in vendor/x11 and drop the link-time libraries, so the same build
/// works natively and when cross-compiling from macOS or Windows, where no
/// Linux X11 or GL libraries exist.
fn useVendoredX11(b: *std.Build, raylib: *std.Build.Step.Compile) void {
    const module = raylib.root_module;
    const loaded_at_runtime = [_][]const u8{ "GL", "X11", "Xrandr", "Xinerama", "Xi", "Xcursor" };
    var kept: usize = 0;
    for (module.link_objects.items) |object| {
        if (object == .system_lib) {
            for (loaded_at_runtime) |name| {
                if (std.mem.eql(u8, object.system_lib.name, name)) break;
            } else {
                module.link_objects.items[kept] = object;
                kept += 1;
            }
        } else {
            module.link_objects.items[kept] = object;
            kept += 1;
        }
    }
    module.link_objects.shrinkRetainingCapacity(kept);
    module.addSystemIncludePath(b.path("vendor/x11/include"));
    // The game never reads images from the clipboard, and on X11 that is the
    // one raylib feature that calls libX11 directly instead of through GLFW.
    module.addCMacro("SUPPORT_CLIPBOARD_IMAGE", "0");
}

/// `zig build -Dtarget=wasm32-emscripten` compiles the game to WebAssembly
/// with Emscripten and installs a static site (index.html, index.js,
/// index.wasm) to zig-out/web, ready for GitHub Pages. The first such build
/// downloads the Emscripten SDK; native builds never do.
fn buildWeb(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const rl = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .rmodels = false,
        .raudio = true,
    });
    const layers = Layers.init(b, target, optimize);
    const game = b.addLibrary(.{
        .name = "archipelagist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = layers.core },
                .{ .name = "shell", .module = layers.shell },
                .{ .name = "raylib", .module = rl.module("raylib") },
            },
        }),
    });
    const emsdk = raylib_build.emsdk;
    var flags = emsdk.emccDefaultFlags(b.allocator, .{ .optimize = optimize, .asyncify = true, .fsanitize = false });
    // Saves live in IndexedDB through Emscripten's IDBFS (see src/app/web/shell.html).
    flags.put("-lidbfs.js", {}) catch @panic("OOM");
    var settings = emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize, .memory_growth = true });
    settings.put("EXPORTED_RUNTIME_METHODS", "['FS','ccall']") catch @panic("OOM");
    // SAFE_HEAP checks every memory access and makes the game crawl.
    _ = settings.remove("SAFE_HEAP");
    // Emscripten's default 64 KiB stack is far smaller than a native thread's
    // 8 MiB. Loading or writing a save keeps a ~200 KiB save.Session and its
    // ~200 KiB encoding on the stack, which overflows 64 KiB and corrupts
    // memory (in ReleaseSmall it shows up as "RuntimeError: null function").
    settings.put("STACK_SIZE", "8388608") catch @panic("OOM");
    const emcc = emsdk.emccStep(b, &.{}, &.{ rl.artifact("raylib"), game }, .{
        .optimize = optimize,
        .flags = flags,
        .settings = settings,
        .shell_file_path = b.path("src/app/web/shell.html"),
        .out_file_name = "index.html",
        .install_dir = .{ .custom = "web" },
    }) catch |err| @panic(@errorName(err));
    b.getInstallStep().dependOn(emcc);
    const emrun = emsdk.emrunStep(b, b.path("zig-out/web/index.html"), &.{}) catch |err| @panic(@errorName(err));
    emrun.dependOn(emcc);
    b.step("run", "Build the browser version and open it with emrun").dependOn(emrun);
}
