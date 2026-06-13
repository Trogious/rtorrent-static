#!/bin/bash
set -euo pipefail

# =============================================================================
# Dynamic rtorrent build script for Ubuntu LTS
# Uses system glibc and packages. Builds libtorrent + rtorrent from source.
# Auto-detects Ubuntu version for artifact naming.
# =============================================================================

BUILD_DIR="/tmp/rtorrent-build"
PREFIX="/usr/local"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# Detect Ubuntu version
. /etc/os-release
UBUNTU_VERSION="$VERSION_ID"
UBUNTU_CODENAME="$VERSION_CODENAME"
UBUNTU_LABEL="$(echo "$VERSION" | grep -oP '\(\K[^)]+' | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
echo "=== Detected Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME) ==="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
$SUDO mkdir -p "$OUTPUT_DIR"
$SUDO chown "$(id -u):$(id -g)" "$OUTPUT_DIR"
cd "$BUILD_DIR"

# =============================================================================
# Step 1: Install system dependencies
# =============================================================================
echo "=== Installing system dependencies ==="
export DEBIAN_FRONTEND=noninteractive
$SUDO ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime
$SUDO apt-get update

# Lua package name varies by Ubuntu version
if apt-cache show liblua5.3-dev &>/dev/null; then
    LUA_DEV="liblua5.3-dev"
    LUA_BIN="lua5.3"
else
    LUA_DEV="liblua5.4-dev"
    LUA_BIN="lua5.4"
fi

$SUDO apt-get install -y \
    build-essential autoconf automake libtool pkg-config git cmake \
    libssl-dev libcurl4-openssl-dev libncursesw5-dev zlib1g-dev \
    "$LUA_DEV" "$LUA_BIN"

# libtorrent >= 0.16.13 requires C++20; Focal's stock toolchain (up to g++-10)
# doesn't pass the AX_CXX_COMPILE_STDCXX(20) probe. Pull g++-13 from
# ubuntu-toolchain-r/test.
if [ "$UBUNTU_CODENAME" = "focal" ]; then
    $SUDO apt-get install -y software-properties-common
    $SUDO add-apt-repository -y ppa:ubuntu-toolchain-r/test
    $SUDO apt-get update
    $SUDO apt-get install -y gcc-13 g++-13
    export CC=gcc-13
    export CXX=g++-13
fi

# =============================================================================
# Step 2: Detect latest libtorrent/rtorrent tags
# =============================================================================
echo "=== Detecting latest release tags ==="
latest_tag() {
    git ls-remote --tags --sort=-v:refname "https://github.com/$1.git" \
        | grep -oP 'refs/tags/v\K[0-9.]+$' | head -1
}

LIBTORRENT_VER="${LIBTORRENT_VERSION:-$(latest_tag rakshasa/libtorrent)}"
RTORRENT_VER="${RTORRENT_VERSION:-$(latest_tag rakshasa/rtorrent)}"
LIBTORRENT_TAG="v${LIBTORRENT_VER}"
RTORRENT_TAG="v${RTORRENT_VER}"
echo "libtorrent: $LIBTORRENT_TAG"
echo "rtorrent:   $RTORRENT_TAG"

# =============================================================================
# Step 3: Build libtorrent
# =============================================================================
echo "=== Building libtorrent $LIBTORRENT_TAG ==="
git clone --depth 1 --branch "$LIBTORRENT_TAG" https://github.com/rakshasa/libtorrent.git
cd libtorrent
autoreconf -fiv
./configure --prefix="$PREFIX"
make
$SUDO make install
$SUDO ldconfig
cd "$BUILD_DIR"

# =============================================================================
# Step 4: Build rtorrent
# =============================================================================
echo "=== Building rtorrent $RTORRENT_TAG ==="
git clone --depth 1 --branch "$RTORRENT_TAG" https://github.com/rakshasa/rtorrent.git
cd rtorrent
autoreconf -fiv
./configure --prefix="$PREFIX" \
    --with-xmlrpc-tinyxml2 \
    --with-lua \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
make
strip --strip-unneeded src/rtorrent
ARTIFACT="rtorrent-${RTORRENT_TAG}-ubuntu-${UBUNTU_LABEL}-x86_64.txz"
# Package rtorrent binary + libtorrent shared library
STAGING="/tmp/rtorrent-pkg"
mkdir -p "$STAGING/bin" "$STAGING/lib"
cp src/rtorrent "$STAGING/bin/"
cp -a "$PREFIX"/lib/libtorrent.so* "$STAGING/lib/"
strip --strip-unneeded "$STAGING"/lib/libtorrent.so.*.*.*
tar cJf "$OUTPUT_DIR/$ARTIFACT" -C "$STAGING" .
echo "$ARTIFACT" > "$OUTPUT_DIR/artifact-name"
echo "$RTORRENT_TAG" > "$OUTPUT_DIR/release-tag"

# Collect library versions for release notes
NCURSES_PKG="libncursesw5-dev"
dpkg -s "$NCURSES_PKG" &>/dev/null || NCURSES_PKG="libncurses-dev"
{
    echo "### Ubuntu ${UBUNTU_VERSION} LTS (${VERSION_CODENAME^}) x86_64"
    echo ""
    echo "#### Compiled from source"
    echo "| Library | Version |"
    echo "|---------|---------|"
    echo "| rtorrent | $RTORRENT_TAG |"
    echo "| libtorrent | $LIBTORRENT_TAG |"
    echo ""
    echo "#### Linked against (system)"
    echo "| Library | Version |"
    echo "|---------|---------|"
    echo "| glibc | $(ldd --version 2>&1 | head -1 | grep -oP '[0-9.]+$') |"
    echo "| OpenSSL | $(openssl version | awk '{print $2}') |"
    echo "| libcurl | $(dpkg -s libcurl4-openssl-dev 2>/dev/null | grep '^Version:' | awk '{print $2}') |"
    echo "| ncurses | $(dpkg -s "$NCURSES_PKG" 2>/dev/null | grep '^Version:' | awk '{print $2}') |"
    echo "| zlib | $(dpkg -s zlib1g-dev 2>/dev/null | grep '^Version:' | awk '{print $2}') |"
    echo "| Lua | $($LUA_BIN -v 2>&1 | awk '{print $2}') |"
    echo "| tinyxml2 | bundled (in rtorrent source) |"
} > "$OUTPUT_DIR/release-notes-${UBUNTU_CODENAME}.md"

cd "$BUILD_DIR"

# =============================================================================
# Verify
# =============================================================================
echo ""
echo "=== Verification ==="

VERIFY_DIR="/tmp/rtorrent-verify"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
tar xJf "$OUTPUT_DIR/$ARTIFACT" -C "$VERIFY_DIR"
BINARY="$VERIFY_DIR/bin/rtorrent"

echo "--- file ---"
file "$BINARY"

echo "--- ldd ---"
ldd "$BINARY"

echo "--- size ---"
ls -lh "$OUTPUT_DIR/$ARTIFACT"

echo "--- version ---"
"$BINARY" --help 2>&1 | head -5 || true

echo ""
echo "=== BUILD COMPLETE: $OUTPUT_DIR/$ARTIFACT ==="
