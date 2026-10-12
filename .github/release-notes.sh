#!/bin/sh
# Print Markdown release notes for the archives in a dist directory.
# usage: .github/release-notes.sh <release-tag> <dist-dir> <owner/repo> <commit-sha>
set -eu

TAG=$1
DIST=$2
REPO=$3
SHA=$4

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NCNN_TAG=$(sed -n 's/^tag=//p' "$ROOT/ncnn.version")
NCNN_COMMIT=$(sed -n 's/^commit=//p' "$ROOT/ncnn.version")
ZIG=$(cat "$ROOT/.zigversion")
URL=https://github.com/$REPO/releases/download/$TAG

# x86_64-linux-gnu.2.17 -> "x86_64 Linux, glibc ≥ 2.17"
describe_target() {
    arch=${1%%-*}
    case "$1" in
        *-linux-gnu.*) echo "$arch Linux, glibc ≥ ${1##*-gnu.}" ;;
        *-linux-musl*) echo "$arch Linux, musl (static)" ;;
        *-windows*) echo "$arch Windows" ;;
        *-macos*) echo "$arch macOS" ;;
        *) echo "$1" ;;
    esac
}

cat <<EOF
Static [ncnn $NCNN_TAG](https://github.com/Tencent/ncnn/releases/tag/$NCNN_TAG) libraries, compiled with **Zig $ZIG**.

| Archive | Variant | Target | Size | Link with |
|---|---|---|---|---|
EOF

EXAMPLE=
for f in $(cd "$DIST" && ls ncnn-*.tar.gz ncnn-*.zip 2>/dev/null | LC_ALL=C sort); do
    name=${f%.tar.gz}
    name=${name%.zip}
    variant=$(printf '%s\n' "$name" | sed -E 's/.*-(cpu|gpu)-.*/\1/')
    target=${name#*-"$variant"-}
    size=$(wc -c < "$DIST/$f" | awk '{ printf "%.1f MB", $1 / 1048576 }')
    case "$variant" in
        cpu) label="CPU"; link="C library only" ;;
        gpu) label="GPU (Vulkan)"; link="libc++ via \`linkLibCpp()\`, Zig $ZIG"; EXAMPLE=${EXAMPLE:-$f} ;;
    esac
    echo "| [\`$f\`]($URL/$f) | $label | $(describe_target "$target") | $size | $link |"
done
EXAMPLE=${EXAMPLE:-$(cd "$DIST" && ls ncnn-*.tar.gz | head -1)}

cat <<EOF

### Use from Zig

\`\`\`sh
zig fetch --save=ncnn $URL/$EXAMPLE
\`\`\`

### Details

- ncnn commit: [\`$(printf '%.7s' "$NCNN_COMMIT")\`](https://github.com/Tencent/ncnn/commit/$NCNN_COMMIT)
- Built from: [\`$(printf '%.7s' "$SHA")\`](https://github.com/$REPO/commit/$SHA)
- Each archive's \`BUILDINFO\` lists the exact target and CMake flags.
- Verify downloads: \`sha256sum -c SHA256SUMS\`
EOF
