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
cp -af c-ares "${OBJROOT}/cares-$ARCH"

# Buildconf
cd "${OBJROOT}/cares-$ARCH"
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
--enable-debug \
--enable-optimize \
--disable-warnings \
--disable-werror \
--disable-curldebug \
--disable-symbol-hiding \
--enable-nonblocking \
--enable-shared \
--disable-static
