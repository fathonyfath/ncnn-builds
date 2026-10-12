# ncnn-zig

Prebuilt static [ncnn](https://github.com/Tencent/ncnn) libraries, compiled with Zig as the C/C++ toolchain.

## Variants

What each variant depends on:

|                         | cpu                                  | gpu                                               |
|-------------------------|--------------------------------------|---------------------------------------------------|
| C library + math (libm) | ✅ glibc (shared) or musl (static)   | ✅ glibc (shared)                                 |
| C++ standard library    | ❌ none (`SIMPLESTL`, `-nostdinc++`) | ✅ libc++, static (from Zig)                      |
| OpenMP runtime          | ❌ none (`SIMPLEOMP`)                | ❌ none (`SIMPLEOMP`)                             |
| Vulkan                  | ❌ not used                          | loaded at runtime (`SIMPLEVK`), nothing to link   |
| Linking it              | any C/Zig toolchain                  | Zig (`linkLibCpp()`), version in `.zigversion`    |

glibc targets are built against an old glibc (2.17) so the result runs on older distros.

## Targets

| Target                   | cpu | gpu | Status                                                                     |
|--------------------------|-----|-----|----------------------------------------------------------------------------|
| `x86_64-linux-gnu.2.17`  | ✅  | ✅  | Built and tested                                                           |
| `aarch64-linux-gnu.2.17` | ➕  | ➕  | Should cross-compile. Untested: to be tested on an ARM CI runner           |
| `x86_64-windows-gnu`     | ➕  | ➕  | Should cross-compile. Untested: to be tested on a Windows CI runner        |
| `aarch64-macos`          | ➕  | ➕  | CPU should work. GPU build probably works, but running it needs MoltenVK   |
| `x86_64-linux-musl`      | ✅  | ❌  | Built and tested, static. No GPU: GPU drivers are glibc libraries          |

✅ done · ➕ planned · ❌ not possible

## Building

Requirements: `cmake`, the Zig version in `.zigversion`, `git`, `tar`/`gzip` (`zip` for Windows targets), `sha256sum`.

```sh
git clone <this repo>
./build.sh cpu x86_64-linux-gnu.2.17
./build.sh gpu x86_64-linux-gnu.2.17
```

`build.sh` fetches ncnn into `ncnn/` at the release pinned in `ncnn.version`, and checks that the tag
still points at the pinned commit. Later builds reuse the checkout.

Archives land in `dist/`:

```
ncnn-<version>-<variant>-<target>/
├── include/ncnn/…
├── lib/libncnn.a            (+ libglslang*.a for gpu)
├── LICENSES/
└── BUILDINFO                ncnn commit, Zig version, target, CMake flags
```

Use `ZIG=/path/to/zig` to pick a specific Zig binary.

## Testing

```sh
zig build test -Darchive=dist/ncnn-<version>-gpu-x86_64-linux-gnu.2.17.tar.gz
```

This unpacks the archive, builds `test/smoke.c` against it for the archive's target, runs SqueezeNet
(`test/models/`, from [ncnn-assets](https://github.com/nihui/ncnn-assets)) and checks that the binary
needs no newer glibc than the target (musl: that it is fully static). The gpu variant falls back to CPU when there is no Vulkan
device; add `-Drequire-vulkan` to make that an error.

## Off-release builds

Build any ncnn tag, branch or commit instead of the pinned release:

```sh
NCNN_REF=master ./build.sh gpu x86_64-linux-gnu.2.17
# -> dist/ncnn-master-20260924-c6b351b-gpu-x86_64-linux-gnu.2.17.tar.gz
```

In CI: Actions → Build → Run workflow, with `ncnn_ref` set. The archives are attached to that run;
off-release builds are never published as releases.

## Updating ncnn

A daily workflow (`update-ncnn.yml`) checks for new ncnn releases. When there is one, it builds and
tests it, then opens a PR that updates `ncnn.version`. Merge the PR, then run **Publish** (below).

To update by hand, edit `ncnn.version`:

```
tag=<new-tag>
commit=<commit the tag points at>
```

## Releasing

Actions → Publish → Run workflow (on `main`). It builds and tests the release pinned in
`ncnn.version`, then creates the tag at that commit and a GitHub release with the archives and
`SHA256SUMS`.

Releases are versioned `<ncnn tag>.<build count>`, picked automatically:

| Situation                                   | Release        | Archive                                      |
|---------------------------------------------|----------------|----------------------------------------------|
| First build of ncnn `20260526`              | `20260526.1`   | `ncnn-20260526.1-gpu-x86_64-linux-gnu.2.17…` |
| Rebuild of the same ncnn (Zig, flags, …)    | `20260526.2`   | `ncnn-20260526.2-gpu-x86_64-linux-gnu.2.17…` |
| ncnn updated to `20261015`                  | `20261015.1`   | `ncnn-20261015.1-gpu-x86_64-linux-gnu.2.17…` |

Earlier releases are never changed, so their URLs and `build.zig.zon` hashes stay valid.

## Using from Zig

Add the archive for your target to `build.zig.zon`:

```sh
zig fetch --save=ncnn_gpu_x86_64_linux https://github.com/fathonyfath/ncnn-zig/releases/download/<release>/ncnn-<release>-gpu-x86_64-linux-gnu.2.17.tar.gz
```

Then in `build.zig`:

```zig
if (b.lazyDependency("ncnn_gpu_x86_64_linux", .{})) |ncnn| {
    exe.addIncludePath(ncnn.path("include"));
    exe.addObjectFile(ncnn.path("lib/libncnn.a"));
    exe.addObjectFile(ncnn.path("lib/libglslang.a"));
    exe.linkLibCpp();
    exe.linkLibC();
}
```
