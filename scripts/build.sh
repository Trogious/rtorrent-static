#!/bin/bash
set -euo pipefail

# =============================================================================
# Static rtorrent build script
# Builds rtorrent and all dependencies from source using musl cross toolchain.
# Runs on Ubuntu (GH Actions runner or local Docker).
# =============================================================================

BUILD_DIR="/tmp/rtorrent-build"
PREFIX="/opt/static-libs"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS

# --- Custom source URLs (passed via environment, set from GH secrets) ---
URL_MUSL_X86_64="${URL_MUSL_X86_64:?URL_MUSL_X86_64 is required}"
URL_ZLIB="${URL_ZLIB:?URL_ZLIB is required}"

# --- Dependency versions ---
OPENSSL_VERSION="3.3.2"
NCURSES_VERSION="6.5"
CURL_VERSION="8.11.1"
TINYXML2_VERSION="10.0.0"
LUA_VERSION="5.3.6"

# --- Source URLs ---
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
NCURSES_URL="https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VERSION}.tar.gz"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
TINYXML2_URL="https://github.com/leethomason/tinyxml2/archive/refs/tags/${TINYXML2_VERSION}.tar.gz"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"

rm -rf "$BUILD_DIR" "$PREFIX"
mkdir -p "$BUILD_DIR" "$PREFIX" "$OUTPUT_DIR"
cd "$BUILD_DIR"

# =============================================================================
# Step 0: Install musl cross toolchain
# =============================================================================
echo "=== Installing musl cross toolchain ==="
curl -L "$URL_MUSL_X86_64" | tar xJ -C /opt/
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
CC=$CC CFLAGS="-O2 -fPIC" ./configure --prefix="$PREFIX" --static
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
    CFLAGS="-O2 -fPIC"
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
    CC="$CC" CXX="$CXX"
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
    CFLAGS="-O2 -fPIC" \
    LDFLAGS="-L$PREFIX/lib" \
    CPPFLAGS="-I$PREFIX/include"
make
make install
cd "$BUILD_DIR"

# =============================================================================
# Step 5: tinyxml2
# =============================================================================
echo "=== Building tinyxml2 ${TINYXML2_VERSION} ==="
curl -L "$TINYXML2_URL" | tar xz
cd tinyxml2-*/
cmake -B build \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_AR="$(which $AR)" \
    -DCMAKE_RANLIB="$(which $RANLIB)" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF
cmake --build build
cmake --install build
cd "$BUILD_DIR"

# =============================================================================
# Step 6: Lua
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
    MYCFLAGS="-fPIC" \
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
# Step 7: mimalloc (replaces musl's single-lock malloc)
# =============================================================================
echo "=== Building mimalloc ==="
MIMALLOC_VERSION="2.1.7"
curl -L "https://github.com/microsoft/mimalloc/archive/refs/tags/v${MIMALLOC_VERSION}.tar.gz" | tar xz
cd mimalloc-*/
cmake -B build \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_AR="$(which $AR)" \
    -DCMAKE_RANLIB="$(which $RANLIB)" \
    -DMI_BUILD_SHARED=OFF \
    -DMI_BUILD_TESTS=OFF \
    -DMI_OVERRIDE=ON \
    -DMI_INSTALL_TOPLEVEL=ON
cmake --build build
cmake --install build
cd "$BUILD_DIR"

# =============================================================================
# Step 8: Detect latest libtorrent/rtorrent tags
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
# Step 9: libtorrent
# =============================================================================
echo "=== Building libtorrent $LIBTORRENT_TAG ==="
git clone --depth 1 --branch "$LIBTORRENT_TAG" https://github.com/rakshasa/libtorrent.git
cd libtorrent
# Patch thread stack size: musl defaults to 128KB, need 8MB like glibc
sed -i '/pthread_create(&m_thread, nullptr,/i\
  pthread_attr_t attr;\
  pthread_attr_init(\&attr);\
  pthread_attr_setstacksize(\&attr, 8 * 1024 * 1024);' src/torrent/system/thread.cc
sed -i 's/pthread_create(&m_thread, nullptr,/pthread_create(\&m_thread, \&attr,/' src/torrent/system/thread.cc
sed -i '/while (m_state != STATE_ACTIVE)/i\
  pthread_attr_destroy(\&attr);' src/torrent/system/thread.cc
# Patch epoll_ctl: handle EBADF/ENOENT gracefully for MOD/DEL (race with curl socket lifecycle)
# EBADF = fd closed by curl before libtorrent could modify/remove it
# ENOENT = fd reused by curl (new socket got same fd number, not yet in epoll)
sed -i '/case EPOLL_CTL_MOD:/,/throw internal_error.*epoll_ctl(MOD).*strerror/ {
  /LT_LOG_EVENT.*EPOLL_CTL_MOD failed:.*strerror/a\
      if (errno == EBADF || errno == ENOENT) { set_event_mask(event, 0); return; }
}' src/torrent/net/poll_epoll.cc
sed -i '/case EPOLL_CTL_DEL:/,/throw internal_error.*epoll_ctl(DEL)/ {
  /LT_LOG_EVENT.*EPOLL_CTL_DEL failed/a\
      if (errno == EBADF || errno == ENOENT) { set_event_mask(event, 0); return; }
}' src/torrent/net/poll_epoll.cc
autoreconf -fiv
./configure \
    --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --disable-execinfo \
    CC="$CC" CXX="$CXX" \
    CFLAGS="-O2 -fno-pie -static" \
    CXXFLAGS="-O2 -fno-pie -static" \
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
# Step 10: rtorrent
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
echo "=== Building debug binary ==="
make clean
./configure \
    --prefix=/usr/local \
    --with-xmlrpc-tinyxml2 \
    --with-lua \
    --disable-execinfo \
    CC="$CC" CXX="$CXX" \
    CFLAGS="-O0 -ggdb -fno-pie -static" \
    CXXFLAGS="-O0 -ggdb -fno-pie -static" \
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
MUSL_VERSION=$($CC -v 2>&1 | grep -oP 'musl-cross-make.*?gcc-\K[0-9.]+' || $CC --version | head -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')
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
| tinyxml2 | ${TINYXML2_VERSION} |
| mimalloc | ${MIMALLOC_VERSION} |
| musl toolchain (gcc) | ${MUSL_VERSION} |

### Patches and modifications
- **epoll_ctl EBADF/ENOENT** (libtorrent): Handle \`EBADF\`/\`ENOENT\` gracefully on \`EPOLL_CTL_MOD\`/\`EPOLL_CTL_DEL\` (race with curl socket lifecycle)
- **pthread stack size** (libtorrent): Explicit 8 MB stack (musl default is 128 KB)
- **mimalloc allocator**: Replaces musl's single-lock malloc with per-thread heaps

### Build flags
- Release: \`-O2\`, stripped
- Debug: \`-O0 -ggdb\`, unstripped, with debug_info
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
file "$VERIFY_DIR/rtorrent-static-debug"

echo "--- size ---"
ls -lh "$OUTPUT_DIR/$ARTIFACT" "$OUTPUT_DIR/$ARTIFACT_DBG"

echo ""
echo "=== BUILD COMPLETE ==="
echo "  Release: $OUTPUT_DIR/$ARTIFACT"
echo "  Debug:   $OUTPUT_DIR/$ARTIFACT_DBG"
