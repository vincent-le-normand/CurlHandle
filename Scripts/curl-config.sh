# First parameter should be "arm" or "x86_64"
MODE=$1

# Second parameter should be "arm64" or "x86_64"
ARCH=$2

# glibtoolize (and maybe other tools) are not supplied with OS X.
# Add default macports & homebrew paths in attempt to find them.
export PATH=${PATH}:/opt/local/bin:/usr/local/bin

# Copy source to a new location to build.
cd "${SRCROOT}/.."
mkdir -p "${OBJROOT}"
cp -af curl "${OBJROOT}/curl-$ARCH"

# Copy libssh2 (we depend on it) headers & dylibs.
cd "${SRCROOT}/../SFTP"
mkdir -p "${OBJROOT}/libssh2/lib"
cp -af libssh2/include "${OBJROOT}/libssh2"
cp -f  libssh2.dylib "${OBJROOT}/libssh2/lib"

# Freaking unbelievably, we also have to copy the libs that libssh2 depends on to the proper relative runtime location, so that the ./configure script can load libssh2 at *configure* time.
cd "${SRCROOT}/../SFTP"
mkdir -p "${OBJROOT}/libssh2/Frameworks"
cp -f libcrypto.dylib "${OBJROOT}/libssh2/Frameworks"
cp -f libssl.dylib "${OBJROOT}/libssh2/Frameworks"

# Copy libcares (we depend on it) headers & dylibs.
cd "${SRCROOT}"
mkdir -p "${OBJROOT}/c-ares-$ARCH/include"
mkdir -p "${OBJROOT}/c-ares-$ARCH/lib"
cp -f ../c-ares/ares*.h "${OBJROOT}/c-ares-$ARCH/include"
# Overwrite generic ares_build.h with the one from our actual build.
cp -f built/include/cares-$ARCH/ares_build.h "${OBJROOT}/c-ares-$ARCH/include/ares_build.h"
cp -f built/libcares.dylib "${OBJROOT}/c-ares-$ARCH/lib"

# Buildconf
cd "${OBJROOT}/curl-$ARCH"
echo "Please ignore any messages about \"No rule to make target distclean.\" That just means the build dir is already clean."
make distclean
echo "***"
echo "***"
echo "*** NOTE: Error messages about installing files are not errors. Please ignore. ***"
echo "***"
echo "***"
./buildconf

# Configure
./configure \
CC="clang" \
CFLAGS="-isysroot ${SDKROOT} -arch $ARCH -g -w -mmacosx-version-min=10.9" \
CPPFLAGS="-DMAC_OS_X_VERSION_MIN_REQUIRED=1090" \
--host=$MODE-apple-darwin10 \
--with-sysroot="${SDKROOT}" \
--with-darwinssl \
--with-libssh2="${OBJROOT}/libssh2" \
--enable-ares="${OBJROOT}/c-ares-$ARCH" \
--without-libidn \
--enable-debug \
--enable-optimize \
--disable-warnings \
--disable-werror \
--disable-curldebug \
--disable-symbol-hiding \
--enable-shared \
--disable-static \
--enable-proxy
##--enable-threaded-resolver [either this or c-ares, this is heavy-uses a thread for every resolve call]
