#!/bin/sh
# Build ncnn with Zig as the C/C++ toolchain and package it as a release archive.
#
# usage: ./build.sh <cpu|gpu> [zig-target]
#   ./build.sh cpu x86_64-linux-gnu.2.17
#   ./build.sh gpu x86_64-linux-gnu.2.17
#
# ncnn is fetched into ./ncnn at the release pinned in ncnn.version (tag + commit, verified).
# NCNN_REF=<tag|branch|commit> builds that ref instead; anything that isn't a release tag is
# labelled <ref>-<commit date>-<short sha>, e.g. master-20260924-c6b351b.
# RELEASE_TAG=<ncnn tag>.<n> (publish workflow) names the archives after that release, e.g. 20260526.1.
#
# Needs: git, cmake, zig (pinned in .zigversion), tar+gzip (zip for windows targets), sha256sum.
# Output: dist/ncnn-<label>-<variant>-<target>.{tar.gz,zip} (+ .sha256)
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
VARIANT=${1:-}
TARGET=${2:-x86_64-linux-gnu.2.17}
ZIG=${ZIG:-zig}

die() { echo "error: $*" >&2; exit 1; }

case "$VARIANT" in
    cpu|gpu) ;;
    *) die "usage: $0 <cpu|gpu> [zig-target]" ;;
esac

# NVIDIA/Mesa drivers on glibc systems can't be loaded into a musl process
case "$TARGET" in
    *-musl*) [ "$VARIANT" = gpu ] && die "gpu variant needs glibc; use a -gnu target" ;;
esac

command -v cmake >/dev/null || die "cmake not found"
command -v "$ZIG" >/dev/null || die "zig not found (set ZIG=/path/to/zig)"

ZIG_VERSION=$("$ZIG" version)
if [ -f "$ROOT/.zigversion" ] && [ "$ZIG_VERSION" != "$(cat "$ROOT/.zigversion")" ]; then
    echo "warning: zig $ZIG_VERSION differs from pinned $(cat "$ROOT/.zigversion")" >&2
fi

NCNN_URL=https://github.com/Tencent/ncnn.git
SRC=$ROOT/ncnn
PIN_TAG=$(sed -n 's/^tag=//p' "$ROOT/ncnn.version")
PIN_COMMIT=$(sed -n 's/^commit=//p' "$ROOT/ncnn.version")
[ -n "$PIN_TAG" ] && [ -n "$PIN_COMMIT" ] || die "ncnn.version needs tag= and commit= lines"
REF=${NCNN_REF:-}

# commit a remote tag points at (annotated tags list the commit under "^{}")
tag_commit() {
    git -C "$SRC" ls-remote origin "refs/tags/$1" "refs/tags/$1^{}" |
        awk -v r="refs/tags/$1" '{ sha[$2] = $1 } END { print (r "^{}" in sha) ? sha[r "^{}"] : sha[r] }'
}

if [ ! -d "$SRC/.git" ]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$NCNN_URL"
fi
if [ -z "$REF" ]; then
    # pinned release; skip the download if it's already checked out
    if [ "$(git -C "$SRC" rev-parse -q --verify HEAD || true)" != "$PIN_COMMIT" ]; then
        git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$PIN_TAG"
        git -C "$SRC" checkout -q --detach FETCH_HEAD
    fi
    [ "$(git -C "$SRC" rev-parse HEAD)" = "$PIN_COMMIT" ] ||
        die "ncnn tag $PIN_TAG is not at $PIN_COMMIT (tag moved upstream?)"
else
    git -C "$SRC" fetch -q --depth 1 origin "$REF"
    git -C "$SRC" checkout -q --detach FETCH_HEAD
fi
git -C "$SRC" submodule update -q --init --depth 1 glslang

NCNN_COMMIT=$(git -C "$SRC" rev-parse HEAD)
if [ -z "$REF" ]; then
    NCNN_TAG=$PIN_TAG
elif [ "$(tag_commit "$REF")" = "$NCNN_COMMIT" ]; then
    NCNN_TAG=$REF  # NCNN_REF named a release tag, e.g. the daily updater testing a new release
else
    NCNN_TAG=
fi

if [ -n "$NCNN_TAG" ]; then
    # release: version is the tag (ncnn tags are dates, e.g. 20260526)
    NCNN_VERSION=$NCNN_TAG
    NCNN_LABEL=$NCNN_TAG
else
    # ncnn uses NCNN_VERSION as a number, so use the commit date; the label carries the rest
    NCNN_VERSION=$(git -C "$SRC" log -1 --format=%cd --date=format:%Y%m%d)
    NCNN_LABEL=$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._\n' '-')-$NCNN_VERSION-$(git -C "$SRC" rev-parse --short=7 HEAD)
    echo "note: $REF is not a release tag; building as $NCNN_LABEL" >&2
fi

# RELEASE_TAG=<ncnn tag>.<build count> (set by the publish workflow) names the archives after our release
RELEASE_TAG=${RELEASE_TAG:-}
if [ -n "$RELEASE_TAG" ]; then
    [ -n "$NCNN_TAG" ] || die "RELEASE_TAG needs ncnn on a release tag"
    case "$RELEASE_TAG" in
        "$NCNN_TAG".[1-9]*) ;;
        *) die "RELEASE_TAG $RELEASE_TAG doesn't match ncnn $NCNN_TAG (expected $NCNN_TAG.<n>)" ;;
    esac
    NCNN_LABEL=$RELEASE_TAG
fi

NAME=ncnn-$NCNN_LABEL-$VARIANT-$TARGET
BUILD=$ROOT/build/$VARIANT-$TARGET
OUT=$ROOT/out/$NAME
DIST=$ROOT/dist

# cpu: no C++ runtime, no OpenMP runtime
# gpu: Vulkan loaded at runtime (SIMPLEVK); glslang needs the real C++ stdlib
# SIMPLEMATH stays off: libm is part of libc on glibc and musl, and ncnn's copies of the
# math functions clash with musl's static libc.a and override glibc's libm app-wide.
COMMON="-DNCNN_THREADS=ON -DNCNN_OPENMP=ON -DNCNN_SIMPLEOMP=ON -DNCNN_SIMPLEMATH=OFF -DNCNN_SHARED_LIB=OFF
-DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_TESTS=OFF -DNCNN_PYTHON=OFF"
if [ "$VARIANT" = cpu ]; then
    FLAGS="-DNCNN_VULKAN=OFF -DNCNN_SIMPLESTL=ON"
    # hide libc++ headers: SIMPLESTL brings its own std::, and libc++'s <math.h> wrapper would clash with it
    CXXFLAGS="-g0 -nostdinc++"
else
    FLAGS="-DNCNN_VULKAN=ON -DNCNN_SIMPLEVK=ON -DNCNN_SIMPLESTL=OFF"
    CXXFLAGS="-g0"
fi

export ZIG ZIG_TARGET="$TARGET"

# drop any previous output first, so a failed build can't leave a stale archive behind
rm -rf "$OUT" "$DIST/$NAME.tar.gz" "$DIST/$NAME.zip" "$DIST/$NAME".*.sha256
# shellcheck disable=SC2086 # word splitting of flag lists is intended
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/zig-toolchain/zig.toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-g0 -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DCMAKE_INSTALL_PREFIX="$OUT" -DNCNN_VERSION="$NCNN_VERSION" \
    $COMMON $FLAGS
cmake --build "$BUILD" -j"$(nproc)"
cmake --install "$BUILD"

# cmake/pkg-config files embed this machine's absolute paths; Zig consumers don't use them
rm -rf "$OUT/lib/cmake" "$OUT/lib/pkgconfig"

mkdir -p "$OUT/LICENSES"
cp "$SRC/LICENSE.txt" "$OUT/LICENSES/ncnn.txt"
[ "$VARIANT" = gpu ] && cp "$SRC/glslang/LICENSE.txt" "$OUT/LICENSES/glslang.txt"

cat > "$OUT/BUILDINFO" <<EOF
ncnn:     ${NCNN_TAG:-$REF} ($NCNN_COMMIT)
release:  $(if [ -n "$RELEASE_TAG" ]; then echo "$RELEASE_TAG"; elif [ -n "$NCNN_TAG" ]; then echo "none (unpublished build)"; else echo "none (off-release ncnn)"; fi)
variant:  $VARIANT
target:   $TARGET
zig:      $ZIG_VERSION
cmake:    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-g0 -DCMAKE_CXX_FLAGS="$CXXFLAGS"
          $(echo $COMMON $FLAGS)
EOF

# deterministic archives: fixed order, timestamps and ownership
mkdir -p "$DIST"
cd "$ROOT/out"
case "$TARGET" in
    *-windows*)
        ARCHIVE=$DIST/$NAME.zip
        rm -f "$ARCHIVE"
        find "$NAME" -exec touch -h -d 1980-01-01T00:00:00Z {} +  # zip can't store dates before 1980
        find "$NAME" | LC_ALL=C sort | zip -q -X -@ "$ARCHIVE"
        ;;
    *)
        ARCHIVE=$DIST/$NAME.tar.gz
        tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "$NAME" | gzip -9n > "$ARCHIVE"
        ;;
esac
cd "$DIST"
sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"

echo "built: $ARCHIVE"
