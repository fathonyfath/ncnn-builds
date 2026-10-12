//! Smoke test for a packaged ncnn archive: unpack it, build test/smoke.c against it, run SqueezeNet.
//! Building the archives themselves is build.sh's job.
//!
//! usage: zig build test -Darchive=dist/ncnn-<label>-<variant>-<target>.tar.gz [-Drequire-vulkan]
const std = @import("std");

pub fn build(b: *std.Build) void {
    const archive = b.option([]const u8, "archive", "Release archive to test (dist/ncnn-<label>-<variant>-<target>.tar.gz)");
    // ncnn silently falls back to CPU without a Vulkan device; this makes that an error
    const require_vulkan = b.option(bool, "require-vulkan", "Fail if the gpu variant doesn't initialize a Vulkan device") orelse false;

    const test_step = b.step("test", "Build test/smoke.c against the archive and run it");
    b.default_step = test_step;

    const archive_path = archive orelse {
        test_step.dependOn(&b.addFail("-Darchive=<path to .tar.gz> is required").step);
        return;
    };

    // ncnn-<label>-<variant>-<target>; the label may contain dashes (e.g. master-20260927-e54f7b1)
    const basename = std.fs.path.basename(archive_path);
    if (!std.mem.endsWith(u8, basename, ".tar.gz")) @panic("-Darchive must be a .tar.gz");
    const name = basename[0 .. basename.len - ".tar.gz".len];
    const gpu = std.mem.find(u8, name, "-gpu-") != null;
    const variant_at = std.mem.findLast(u8, name, if (gpu) "-gpu-" else "-cpu-") orelse
        @panic("archive name has no -cpu- or -gpu- part");
    const query = std.Target.Query.parse(.{ .arch_os_abi = name[variant_at + "-cpu-".len ..] }) catch
        @panic("archive name doesn't end in a Zig target");

    const unpack = b.addSystemCommand(&.{ "tar", "xzf" });
    unpack.addFileArg(.{ .cwd_relative = archive_path });
    unpack.addArgs(&.{ "--strip-components=1", "-C" });
    const pkg = unpack.addOutputDirectoryArg("ncnn");

    const mod = b.createModule(.{
        .target = b.resolveTargetQuery(query),
        .optimize = .ReleaseFast,
        .strip = true,
        .link_libc = true,
        // gpu: glslang needs the real C++ stdlib
        .link_libcpp = gpu,
    });
    mod.addCSourceFile(.{ .file = b.path("test/smoke.c") });
    mod.addIncludePath(pkg.path(b, "include"));
    mod.addObjectFile(pkg.path(b, "lib/libncnn.a"));
    if (gpu) mod.addObjectFile(pkg.path(b, "lib/libglslang.a"));
    // musl: fully static, so the binary runs on any Linux
    const musl = query.abi != null and query.abi.?.isMusl();
    const smoke = b.addExecutable(.{ .name = "smoke", .root_module = mod, .linkage = if (musl) .static else null });

    const run = b.addRunArtifact(smoke);
    run.addFileArg(b.path("test/models/squeezenet_v1.1.param"));
    run.addFileArg(b.path("test/models/squeezenet_v1.1.bin"));
    if (gpu) run.addArg("gpu");
    run.has_side_effects = true; // depends on the machine (Vulkan drivers), so never reuse a cached result
    run.expectExitCode(0);
    run.expectStdOutMatch("1000 classes");
    // ncnn prints "[0 <device name>] ..." once it initializes a device
    if (gpu and require_vulkan) run.expectStdErrMatch("[0 ");
    test_step.dependOn(&run.step);

    // glibc targets must not need a newer glibc than the one they were built for;
    // musl binaries must not need anything
    const requirement: ?[]const u8 = if (query.glibc_version) |want|
        b.fmt("{d}.{d}", .{ want.major, want.minor })
    else if (musl) "static" else null;
    if (requirement) |arg| {
        const check = b.addRunArtifact(b.addExecutable(.{
            .name = "check-binary",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/check_binary.zig"),
                .target = b.graph.host,
            }),
        }));
        check.addArtifactArg(smoke);
        check.addArg(arg);
        test_step.dependOn(&check.step);
    }
}
