#!/bin/bash
set -euo pipefail

# =============================================================================
# Static rtorrent build script
# Builds rtorrent and all dependencies from source using musl cross toolchain.
# Runs on Ubuntu (GH Actions runner or local Docker).
#
# Runs as an unprivileged user. sudo is used only for the few steps that write
# outside user-writable locations: creating $PREFIX under /opt, creating
# $OUTPUT_DIR, and extracting the toolchain into /opt. Everything else
# (downloads, builds, installs into $PREFIX, packaging) runs as the caller.
#
# Debug info: every dependency is compiled with -ggdb (at its normal
# optimisation level) so the unstripped debug binary carries DWARF for
# libtorrent and all libraries, not only for rtorrent itself. The release
# binary is stripped, so it is unaffected. See "Build flags" in the release
# notes below.
# =============================================================================

BUILD_DIR="/tmp/rtorrent-build"
PREFIX="/opt/static-libs"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# --- Custom source URLs (passed via environment, set from GH secrets) ---
URL_MUSL_X86_64="${URL_MUSL_X86_64:?URL_MUSL_X86_64 is required}"
URL_ZLIB="${URL_ZLIB:?URL_ZLIB is required}"

# --- Dependency versions ---
OPENSSL_VERSION="3.3.2"
NCURSES_VERSION="6.5"
CURL_VERSION="8.11.1"
LUA_VERSION="5.3.6"

# --- Source URLs ---
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
NCURSES_URL="https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VERSION}.tar.gz"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
# $PREFIX (under /opt) and $OUTPUT_DIR (/output by default) are root-only
# locations: create them as root, then hand them to the build user so every
# install and packaging step below runs unprivileged.
$SUDO rm -rf "$PREFIX"
$SUDO mkdir -p "$PREFIX" "$OUTPUT_DIR"
$SUDO chown "$(id -u):$(id -g)" "$PREFIX" "$OUTPUT_DIR"
cd "$BUILD_DIR"

# =============================================================================
# Step 0: Install musl cross toolchain
# =============================================================================
echo "=== Installing musl cross toolchain ==="
# /opt is root-owned, so only the extraction is elevated; the toolchain is
# only ever executed from there, never written to, after this point.
curl -L "$URL_MUSL_X86_64" | $SUDO tar xJ -C /opt/
# Discover the extracted directory name
MUSL_CROSS_DIR=$(ls -d /opt/*-linux-musl-cross 2>/dev/null | head -1)
if [ -z "$MUSL_CROSS_DIR" ]; then
    echo "FATAL: musl cross toolchain not found after extraction"
    exit 1
fi
export PATH="$MUSL_CROSS_DIR/bin:$PATH"

# Discover the toolchain prefix (e.g., x86_64-linux-musl-)
CROSS_PREFIX=$(basename "$MUSL_CROSS_DIR" | sed 's/-cross$//')
export CC="${CROSS_PREFIX}-gcc"
export CXX="${CROSS_PREFIX}-g++"
export AR="${CROSS_PREFIX}-ar"
export RANLIB="${CROSS_PREFIX}-ranlib"
export STRIP="${CROSS_PREFIX}-strip"
export HOST_TRIPLET="$CROSS_PREFIX"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

echo "Toolchain: CC=$CC CXX=$CXX HOST=$HOST_TRIPLET"
echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
$CC --version | head -1

# =============================================================================
# Step 1: zlib
# =============================================================================
echo "=== Building zlib ==="
curl -L "$URL_ZLIB" | tar xz
cd zlib-*/
CC=$CC CFLAGS="-O2 -ggdb -fPIC" ./configure --prefix="$PREFIX" --static
make
make install
ZLIB_VERSION=$(pkg-config --modversion zlib 2>/dev/null || grep -oP 'Version: \K.*' "$PREFIX/lib/pkgconfig/zlib.pc")
cd "$BUILD_DIR"

# =============================================================================
# Step 2: OpenSSL
# =============================================================================
echo "=== Building OpenSSL ${OPENSSL_VERSION} ==="
curl -L "$OPENSSL_URL" | tar xz
cd openssl-*/
./Configure linux-x86_64 \
    --prefix="$PREFIX" \
    --openssldir=/etc/ssl \
    no-shared no-dso no-tests no-engine \
    CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="-O2 -ggdb -fPIC"
make
make install_sw
cd "$BUILD_DIR"

# =============================================================================
# Step 3: ncurses
# =============================================================================
echo "=== Building ncurses ${NCURSES_VERSION} ==="
curl -L "$NCURSES_URL" | tar xz
cd ncurses-*/
./configure \
    --prefix="$PREFIX" \
    --host="$HOST_TRIPLET" \
    --enable-static --disable-shared \
    --enable-widec --enable-overwrite \
    --without-debug --without-ada --without-tests --without-manpages \
    --without-cxx-binding \
    --with-default-terminfo-dir=/etc/terminfo \
    --with-terminfo-dirs="/etc/terminfo:/lib/terminfo:/usr/share/terminfo" \
    --disable-db-install \
    CC="$CC" CXX="$CXX" \
    CFLAGS="-O2 -ggdb"
# --disable-db-install: "make install" would otherwise compile the terminfo
# database into --with-default-terminfo-dir (/etc/terminfo), which needs root.
# The build only needs the library and headers; the static rtorrent reads the
# target host's own terminfo from the compiled-in search dirs at runtime.
make
make install
# Create non-wide symlinks so -lncurses finds ncursesw
cd "$PREFIX/lib"
for lib in libncursesw.a libpanelw.a libmenuw.a libformw.a; do
    target="${lib/w.a/.a}"
    [ -f "$lib" ] && [ ! -f "$target" ] && ln -s "$lib" "$target"
done
cd "$PREFIX/include"
[ ! -d ncurses ] && ln -s ncursesw ncurses
cd "$BUILD_DIR"

# =============================================================================
# Step 4: curl
# =============================================================================
echo "=== Building curl ${CURL_VERSION} ==="
curl -L "$CURL_URL" | tar xz
cd curl-*/
./configure \
    --prefix="$PREFIX" \
    --host="$HOST_TRIPLET" \
    --enable-static --disable-shared \
    --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
    --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
    --with-ca-path=/etc/ssl/certs \
    --without-libpsl --without-brotli --without-zstd \
    --without-nghttp2 --without-libidn2 --without-libssh2 \
    --disable-ldap --disable-dict --disable-telnet \
    --disable-tftp --disable-pop3 --disable-imap \
    --disable-smb --disable-smtp --disable-gopher \
    --disable-rtsp --disable-file --disable-ftp \
    --disable-manual --disable-docs \
    CC="$CC" CXX="$CXX" \
    CFLAGS="-O2 -ggdb -fPIC" \
    LDFLAGS="-L$PREFIX/lib" \
    CPPFLAGS="-I$PREFIX/include"
make
make install
cd "$BUILD_DIR"

# =============================================================================
# Step 5: Lua
# =============================================================================
echo "=== Building Lua ${LUA_VERSION} ==="
curl -L "$LUA_URL" | tar xz
cd lua-*/
# Use "posix" target — "linux" requires readline which we don't need
# MYLDFLAGS=-static so the lua binary runs on the glibc build host
make posix \
    CC="$CC" \
    AR="$AR rcs" \
    RANLIB="$RANLIB" \
    MYCFLAGS="-ggdb -fPIC" \
    MYLDFLAGS="-static"
make install INSTALL_TOP="$PREFIX"
# Create pkg-config file for Lua (not shipped by default)
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/lua.pc" <<LUAPC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Lua
Description: Lua language engine
Version: $LUA_VERSION
Libs: -L\${libdir} -llua -lm
Cflags: -I\${includedir}
LUAPC
cd "$BUILD_DIR"

# =============================================================================
# Step 6: mimalloc (replaces musl's single-lock malloc)
# =============================================================================
echo "=== Building mimalloc ==="
MIMALLOC_VERSION="2.1.7"
curl -L "https://github.com/microsoft/mimalloc/archive/refs/tags/v${MIMALLOC_VERSION}.tar.gz" | tar xz
cd mimalloc-*/
# Release (-O3 -DNDEBUG) is what mimalloc defaulted to before; pin it so the
# allocator keeps NDEBUG (no MI_DEBUG assertions) and only gains -ggdb.
cmake -B build \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_AR="$(which $AR)" \
    -DCMAKE_RANLIB="$(which $RANLIB)" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -ggdb -DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -ggdb -DNDEBUG" \
    -DMI_BUILD_SHARED=OFF \
    -DMI_BUILD_TESTS=OFF \
    -DMI_OVERRIDE=ON \
    -DMI_INSTALL_TOPLEVEL=ON
cmake --build build
cmake --install build
cd "$BUILD_DIR"

# =============================================================================
# Step 7: Detect latest libtorrent/rtorrent tags
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
# Step 8: libtorrent
# =============================================================================
echo "=== Building libtorrent $LIBTORRENT_TAG ==="
git clone --depth 1 --branch "$LIBTORRENT_TAG" https://github.com/rakshasa/libtorrent.git
cd libtorrent
# Patch epoll_ctl: handle EBADF/ENOENT gracefully for MOD/DEL (race with curl socket lifecycle)
# EBADF = fd closed by curl before libtorrent could modify/remove it
# ENOENT = fd reused by curl (new socket got same fd number, not yet in epoll)
sed -i '/case EPOLL_CTL_MOD:/,/throw internal_error.*epoll_ctl(MOD).*strerror/ {
  /LT_LOG_EVENT.*EPOLL_CTL_MOD failed:.*strerror/a\
      if (errno == EBADF || errno == ENOENT) { set_event_mask(event, 0); return; }
}' src/torrent/system/poll_epoll.cc
sed -i '/case EPOLL_CTL_DEL:/,/throw internal_error.*epoll_ctl(DEL)/ {
  /LT_LOG_EVENT.*EPOLL_CTL_DEL failed/a\
      if (errno == EBADF || errno == ENOENT) { set_event_mask(event, 0); return; }
}' src/torrent/system/poll_epoll.cc
autoreconf -fiv
./configure \
    --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --enable-pthread-setstacksize \
    --disable-execinfo \
    CC="$CC" CXX="$CXX" \
    CFLAGS="-O2 -ggdb -fno-pie -static" \
    CXXFLAGS="-O2 -ggdb -fno-pie -static" \
    LDFLAGS="-no-pie -static -L$PREFIX/lib" \
    CPPFLAGS="-I$PREFIX/include"
make
make install
# Remove .la files — libtool dependency tracking breaks with cross toolchains
find "$PREFIX/lib" -name '*.la' -delete
# Patch libtorrent.pc so pkg-config --static pulls in transitive deps
if [ -f "$PREFIX/lib/pkgconfig/libtorrent.pc" ]; then
    echo "Requires.private: libcurl libcrypto zlib" >> "$PREFIX/lib/pkgconfig/libtorrent.pc"
fi
cd "$BUILD_DIR"

# =============================================================================
# Step 9: rtorrent
# =============================================================================
echo "=== Building rtorrent $RTORRENT_TAG ==="
git clone --depth 1 --branch "$RTORRENT_TAG" https://github.com/rakshasa/rtorrent.git
cd rtorrent
autoreconf -fiv
# Add PREFIX/bin to PATH so configure finds the Lua interpreter
export PATH="$PREFIX/bin:$PATH"

# --- Release build ---
echo "=== Building release binary ==="
./configure \
    --prefix=/usr/local \
    --with-xmlrpc-tinyxml2 \
    --with-lua \
    --disable-execinfo \
    CC="$CC" CXX="$CXX" \
    CFLAGS="-O2 -fno-pie -static" \
    CXXFLAGS="-O2 -fno-pie -static" \
    LDFLAGS="-no-pie -static -L$PREFIX/lib" \
    CPPFLAGS="-I$PREFIX/include" \
    PKG_CONFIG="pkg-config --static"
# Inject -all-static into Makefile so libtool produces a fully static binary
sed -i 's/^LDFLAGS = .*/& -all-static/' src/Makefile
sed -i 's/^LIBS = .*/& -lmimalloc/' src/Makefile
make
cp src/rtorrent src/rtorrent-static
$STRIP --strip-all src/rtorrent-static

# --- Debug build ---
# Same -O2 code as the release build, plus -ggdb, left unstripped: crashes
# reproduce identically and every frame (rtorrent, libtorrent, libraries)
# resolves to file:line.
echo "=== Building debug binary ==="
make clean
./configure \
    --prefix=/usr/local \
    --with-xmlrpc-tinyxml2 \
    --with-lua \
    --disable-execinfo \
    CC="$CC" CXX="$CXX" \
    CFLAGS="-O2 -ggdb -fno-pie -static" \
    CXXFLAGS="-O2 -ggdb -fno-pie -static" \
    LDFLAGS="-no-pie -static -L$PREFIX/lib" \
    CPPFLAGS="-I$PREFIX/include" \
    PKG_CONFIG="pkg-config --static"
sed -i 's/^LDFLAGS = .*/& -all-static/' src/Makefile
sed -i 's/^LIBS = .*/& -lmimalloc/' src/Makefile
make

# --- Package both ---
ARTIFACT="rtorrent-static-${RTORRENT_TAG}.txz"
ARTIFACT_DBG="rtorrent-static-${RTORRENT_TAG}-debug.txz"
cp src/rtorrent src/rtorrent-static-debug
tar cJf "$OUTPUT_DIR/$ARTIFACT" -C src rtorrent-static
tar cJf "$OUTPUT_DIR/$ARTIFACT_DBG" -C src rtorrent-static-debug
echo "$ARTIFACT" > "$OUTPUT_DIR/artifact-name"

# --- Release notes ---
# -dumpfullversion is canonical (e.g. "13.2.0"); -dumpversion is the fallback for
# older GCCs that don't support it. Fail loudly if neither produces output so
# we never publish a release with a blank toolchain version.
GCC_VERSION=$("$CC" -dumpfullversion 2>/dev/null || "$CC" -dumpversion)
: "${GCC_VERSION:?failed to detect GCC version from $CC}"
# tinyxml2 is not a separate dependency: rtorrent compiles its own vendored
# copy (src/rpc/tinyxml2/), so report that copy's version. The header has
# CRLF line endings, hence the gsub.
TINYXML2_VERSION=$(awk '/#define TINYXML2_(MAJOR|MINOR|PATCH)_VERSION/ { gsub(/\r/, ""); v[$2] = $3 }
    END { print v["TINYXML2_MAJOR_VERSION"] "." v["TINYXML2_MINOR_VERSION"] "." v["TINYXML2_PATCH_VERSION"] }' \
    src/rpc/tinyxml2/tinyxml2.h)
if ! [[ "$TINYXML2_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "FATAL: failed to detect vendored tinyxml2 version (got '$TINYXML2_VERSION')"
    exit 1
fi
cat > "$OUTPUT_DIR/release-notes.md" <<NOTES
## Static musl build — x86_64

Fully static binary. No runtime dependencies. Runs on any x86_64 Linux.

### All libraries compiled from source
| Library | Version |
|---------|---------|
| rtorrent | ${RTORRENT_TAG} |
| libtorrent | ${LIBTORRENT_TAG} |
| OpenSSL | ${OPENSSL_VERSION} |
| curl | ${CURL_VERSION} |
| ncurses | ${NCURSES_VERSION} |
| zlib | ${ZLIB_VERSION} |
| Lua | ${LUA_VERSION} |
| tinyxml2 (vendored in rtorrent) | ${TINYXML2_VERSION} |
| mimalloc | ${MIMALLOC_VERSION} |
| musl toolchain (gcc) | ${GCC_VERSION} |

### Patches and modifications
- **epoll_ctl EBADF/ENOENT** (libtorrent): Handle \`EBADF\`/\`ENOENT\` gracefully on \`EPOLL_CTL_MOD\`/\`EPOLL_CTL_DEL\` (race with curl socket lifecycle)
- **pthread stack size** (libtorrent ≥ 0.16.13, upstream): \`--enable-pthread-setstacksize\` sets 8 MB stack (musl default is 128 KB)
- **mimalloc allocator**: Replaces musl's single-lock malloc with per-thread heaps

### Build flags
- Release: \`-O2\`, stripped
- Debug: \`-O2 -ggdb\`, unstripped. All libraries above are compiled with \`-ggdb\` too (\`-O2\`; mimalloc \`-O3\`), so debug info covers rtorrent, libtorrent and every dependency
NOTES
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
BINARY="$VERIFY_DIR/rtorrent-static"

echo "--- file (release) ---"
file "$BINARY"

echo "--- link check ---"
if file "$BINARY" | grep -q "statically linked"; then
    echo "PASS: Binary is statically linked"
else
    echo "FAIL: Binary is NOT statically linked"
    file "$BINARY"
    exit 1
fi

echo "--- file (debug) ---"
tar xJf "$OUTPUT_DIR/$ARTIFACT_DBG" -C "$VERIFY_DIR"
BINARY_DBG="$VERIFY_DIR/rtorrent-static-debug"
file "$BINARY_DBG"

echo "--- debug info check ---"
# The debug binary must carry DWARF compile units from every source tree that
# ends up linked in, not only from rtorrent itself: count DW_AT_comp_dir
# entries per dependency directory under $BUILD_DIR. tinyxml2 is not in the
# list because rtorrent compiles its own vendored copy (src/rpc/tinyxml2/)
# rather than linking the one from $PREFIX; that unit is checked by name.
READELF="${CROSS_PREFIX}-readelf"
command -v "$READELF" >/dev/null 2>&1 || READELF=readelf
"$READELF" --debug-dump=info --dwarf-depth=1 "$BINARY_DBG" \
    | grep -E 'DW_AT_(name|comp_dir)' > "$VERIFY_DIR/dwarf_cus.txt"
DEBUG_INFO_OK=1
for tree in zlib- openssl- ncurses- curl- lua- mimalloc- libtorrent rtorrent; do
    n=$(grep -F 'DW_AT_comp_dir' "$VERIFY_DIR/dwarf_cus.txt" | grep -c -F "$BUILD_DIR/$tree" || true)
    if [ "$n" -gt 0 ]; then
        echo "PASS: $n compile units with debug info from $tree"
    else
        echo "FAIL: no debug info from $tree"
        DEBUG_INFO_OK=0
    fi
done
# (single grep, no pipe: with pipefail, grep -q closing the pipe early would
# make the pipeline fail on a match)
if grep -E 'DW_AT_name.*tinyxml2/tinyxml2' "$VERIFY_DIR/dwarf_cus.txt" >/dev/null; then
    echo "PASS: debug info for rtorrent's vendored tinyxml2"
else
    echo "FAIL: no debug info for rtorrent's vendored tinyxml2"
    DEBUG_INFO_OK=0
fi
if [ "$DEBUG_INFO_OK" -ne 1 ]; then
    echo "FAIL: debug binary is missing debug info for some dependencies"
    exit 1
fi
if file "$BINARY" | grep -q "not stripped"; then
    echo "FAIL: release binary is not stripped"
    exit 1
fi

echo "--- size ---"
ls -lh "$OUTPUT_DIR/$ARTIFACT" "$OUTPUT_DIR/$ARTIFACT_DBG"

echo ""
echo "=== BUILD COMPLETE ==="
echo "  Release: $OUTPUT_DIR/$ARTIFACT"
echo "  Debug:   $OUTPUT_DIR/$ARTIFACT_DBG"
