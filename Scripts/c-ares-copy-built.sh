# First parameter should be "arm64" or "x86_64"
MODE=$1

# Copy ares_build.h for use by libcurl compile.
cd "${OBJROOT}/cares-$MODE"
cp -f ares_build.h ares_build-$MODE.h
