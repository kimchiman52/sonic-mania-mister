# Cross-compile toolchain for MiSTer HPS (Cortex-A9, armhf, Debian Bullseye).
#
# Intentionally MINIMAL: we do NOT set CMAKE_SYSROOT or CMAKE_FIND_ROOT_PATH.
# Debian's multi-arch layout puts armhf libs at /usr/lib/arm-linux-gnueabihf/
# and armhf headers at /usr/include/arm-linux-gnueabihf/, both of which
# clang-20 picks up automatically when given `--target=arm-linux-gnueabihf`
# and `--gcc-toolchain=/usr`. Setting CMAKE_SYSROOT here would hide those
# paths and break pkg-config / SDL2 / theora discovery under a cross build.
#
# This toolchain file is an ergonomic alternative to the env-var form used
# by tools/mister/build-game.sh (which matches the sibling 3sx-mister
# pattern byte-for-byte). Both are supported; the build driver uses env
# vars and DOES NOT pass --toolchain. A human running `cmake` directly may
# pass `-DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mister.cmake` instead.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR armv7-a)
set(CMAKE_C_COMPILER clang-20)
set(CMAKE_CXX_COMPILER clang++-20)
set(CMAKE_C_COMPILER_TARGET arm-linux-gnueabihf)
set(CMAKE_CXX_COMPILER_TARGET arm-linux-gnueabihf)

set(CMAKE_C_FLAGS_INIT "--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include")
set(CMAKE_CXX_FLAGS_INIT "--target=arm-linux-gnueabihf --gcc-toolchain=/usr -isystem /usr/arm-linux-gnueabihf/include")
set(CMAKE_EXE_LINKER_FLAGS_INIT "--target=arm-linux-gnueabihf --gcc-toolchain=/usr")

# Point pkg-config at armhf .pc files before host-arch ones.
set(ENV{PKG_CONFIG_LIBDIR} "/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig")
