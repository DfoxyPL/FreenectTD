#!/bin/bash
# Builds x86_64 (Intel) versions of the bundled static libraries and merges
# them with the existing arm64 ones into universal archives in include/libs.
#
# Usage: ./scripts/build_universal_libs.sh
# Requires: Xcode command line tools, cmake, autoconf/automake/libtool, pkg-config
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBS="$ROOT/include/libs"
WORK="${WORK_DIR:-$ROOT/build_deps}"
PREFIX="$WORK/prefix-x86_64"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
ARCH=x86_64

LIBUSB_VER=1.0.29
LIBFREENECT_VER=0.7.5
LIBFREENECT2_VER=0.2.0

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

# ---------------------------------------------------------------- libusb
if [ ! -f "$PREFIX/lib/libusb-1.0.a" ]; then
    curl -fsSL -o libusb.tar.bz2 \
        "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VER}/libusb-${LIBUSB_VER}.tar.bz2"
    rm -rf "libusb-${LIBUSB_VER}" && tar xjf libusb.tar.bz2
    (
        cd "libusb-${LIBUSB_VER}"
        ./configure --host=x86_64-apple-darwin --prefix="$PREFIX" \
            --disable-shared --enable-static \
            CC="clang -arch $ARCH" CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
fi

CMAKE_COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=$ARCH
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_PREFIX_PATH="$PREFIX"
    # Never pick up arm64 Homebrew packages when cross-building for Intel
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
)
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# ------------------------------------------------------------ libfreenect
if [ ! -f "$WORK/libfreenect-build/lib/libfreenect.a" ]; then
    curl -fsSL -o libfreenect.tar.gz \
        "https://github.com/OpenKinect/libfreenect/archive/refs/tags/v${LIBFREENECT_VER}.tar.gz"
    rm -rf "libfreenect-${LIBFREENECT_VER}" && tar xzf libfreenect.tar.gz
    cmake -S "libfreenect-${LIBFREENECT_VER}" -B libfreenect-build "${CMAKE_COMMON[@]}" \
        -DBUILD_EXAMPLES=OFF -DBUILD_FAKENECT=OFF -DBUILD_C_SYNC=OFF -DBUILD_CPP=OFF \
        -DBUILD_CV=OFF -DBUILD_AS3_SERVER=OFF -DBUILD_PYTHON=OFF -DBUILD_PYTHON2=OFF \
        -DBUILD_PYTHON3=OFF -DBUILD_OPENNI2_DRIVER=OFF -DBUILD_REDIST_PACKAGE=OFF \
        -DLIBUSB_1_INCLUDE_DIR="$PREFIX/include/libusb-1.0" \
        -DLIBUSB_1_LIBRARY="$PREFIX/lib/libusb-1.0.a"
    cmake --build libfreenect-build --target freenectstatic -j"$(sysctl -n hw.ncpu)"
fi

# ----------------------------------------------------------- libfreenect2
# Same feature set as the bundled arm64 build (OpenCL + VideoToolbox, CPU depth),
# minus OpenGL and TurboJPEG which the plugin neither uses nor links.
if [ ! -f "$WORK/libfreenect2-build/lib/libfreenect2.a" ]; then
    curl -fsSL -o libfreenect2.tar.gz \
        "https://github.com/OpenKinect/libfreenect2/archive/refs/tags/v${LIBFREENECT2_VER}.tar.gz"
    rm -rf "libfreenect2-${LIBFREENECT2_VER}" && tar xzf libfreenect2.tar.gz
    cmake -S "libfreenect2-${LIBFREENECT2_VER}" -B libfreenect2-build "${CMAKE_COMMON[@]}" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_OPENNI2_DRIVER=OFF \
        -DENABLE_CXX11=ON -DENABLE_OPENGL=OFF -DENABLE_OPENCL=ON -DENABLE_CUDA=OFF \
        -DENABLE_VAAPI=OFF -DENABLE_TEGRAJPEG=OFF -DENABLE_PROFILING=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_TurboJPEG=ON \
        -DLibUSB_INCLUDE_DIRS="$PREFIX/include/libusb-1.0" \
        -DLibUSB_LIBRARIES="$PREFIX/lib/libusb-1.0.a" \
        -DLibUSB_INCLUDE_DIR="$PREFIX/include/libusb-1.0" \
        -DLibUSB_LIBRARY="$PREFIX/lib/libusb-1.0.a"
    cmake --build libfreenect2-build --target freenect2 -j"$(sysctl -n hw.ncpu)"
fi

# --------------------------------------------------------- merge (lipo)
merge() {
    local bundled="$1" x86="$2"
    local thin_arm="$WORK/$(basename "$bundled" .a).arm64.a"
    if lipo -info "$bundled" | grep -q x86_64; then
        echo "$(basename "$bundled") already contains x86_64, skipping"
        return
    fi
    cp "$bundled" "$thin_arm"
    lipo -create "$thin_arm" "$x86" -output "$bundled"
    lipo -info "$bundled"
}

X86_FN="$(find "$WORK/libfreenect-build" -name 'libfreenect.a' | head -n1)"
X86_FN2="$(find "$WORK/libfreenect2-build" -name 'libfreenect2.a' | head -n1)"

merge "$LIBS/libusb_${LIBUSB_VER}.a"             "$PREFIX/lib/libusb-1.0.a"
merge "$LIBS/libfreenect_${LIBFREENECT_VER}.a"   "$X86_FN"
merge "$LIBS/libfreenect2_${LIBFREENECT2_VER}.a" "$X86_FN2"

echo "Universal libraries ready in $LIBS"
