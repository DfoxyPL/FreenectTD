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
# The bundled headers (include/headers/libfreenect2) come from libfreenect2 master,
# whose Freenect2Device vtable differs from the v0.2.0 tag. Build the same commit.
LIBFREENECT2_REF=fd64c5d9b214df6f6a55b4419357e51083f15d93
LIBJPEG_TURBO_VER=3.0.4

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

# --------------------------------------------------------- libjpeg-turbo
# Software JPEG decoder for the Kinect v2 color stream on Intel. libfreenect2's
# VideoToolbox decoder has no error handling and crashes on Macs (and
# Hackintoshes) where hardware JPEG decoding is unavailable.
if [ ! -f "$PREFIX/lib/libturbojpeg.a" ]; then
    curl -fsSL -o libjpeg-turbo.tar.gz \
        "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_TURBO_VER}/libjpeg-turbo-${LIBJPEG_TURBO_VER}.tar.gz"
    rm -rf "libjpeg-turbo-${LIBJPEG_TURBO_VER}" && tar xzf libjpeg-turbo.tar.gz
    cmake -S "libjpeg-turbo-${LIBJPEG_TURBO_VER}" -B libjpeg-turbo-build "${CMAKE_COMMON[@]}" \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_INSTALL_LIBDIR=lib \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=ON -DWITH_JAVA=OFF
    cmake --build libjpeg-turbo-build -j"$(sysctl -n hw.ncpu)"
    cmake --install libjpeg-turbo-build
fi

# ----------------------------------------------------------- libfreenect2
# Same feature set as the bundled arm64 build (OpenCL, CPU depth) minus OpenGL,
# which the plugin doesn't use, and with TurboJPEG instead of VideoToolbox.
if [ ! -f "$WORK/libfreenect2-build-master/lib/libfreenect2.a" ]; then
    curl -fsSL -o libfreenect2.tar.gz \
        "https://github.com/OpenKinect/libfreenect2/archive/${LIBFREENECT2_REF}.tar.gz"
    FN2_SRC="libfreenect2-${LIBFREENECT2_REF}"
    rm -rf "$FN2_SRC" && tar xzf libfreenect2.tar.gz
    # Fail fast if the library sources don't match the headers the plugin compiles against
    for h in libfreenect2.hpp frame_listener.hpp frame_listener_impl.h packet_pipeline.h \
             registration.h color_settings.h led_settings.h; do
        cmp "$ROOT/include/headers/libfreenect2/$h" "$FN2_SRC/include/libfreenect2/$h"
    done
    # libfreenect2 always prefers VideoToolbox on Apple; make it optional.
    perl -pi -e 's/IF\(VIDEOTOOLBOX_LIBRARY\)/IF(VIDEOTOOLBOX_LIBRARY AND NOT FNTD_DISABLE_VT)/; s/ENDIF\(VIDEOTOOLBOX_LIBRARY\)/ENDIF()/' \
        "$FN2_SRC/CMakeLists.txt"
    cmake -S "$FN2_SRC" -B libfreenect2-build-master "${CMAKE_COMMON[@]}" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_OPENNI2_DRIVER=OFF \
        -DENABLE_CXX11=ON -DENABLE_OPENGL=OFF -DENABLE_OPENCL=ON -DENABLE_CUDA=OFF \
        -DENABLE_VAAPI=OFF -DENABLE_TEGRAJPEG=OFF -DENABLE_PROFILING=OFF \
        -DFNTD_DISABLE_VT=ON \
        -DTurboJPEG_INCLUDE_DIRS="$PREFIX/include" \
        -DTurboJPEG_LIBRARIES="$PREFIX/lib/libturbojpeg.a" \
        -DLibUSB_INCLUDE_DIRS="$PREFIX/include/libusb-1.0" \
        -DLibUSB_LIBRARIES="$PREFIX/lib/libusb-1.0.a" \
        -DLibUSB_INCLUDE_DIR="$PREFIX/include/libusb-1.0" \
        -DLibUSB_LIBRARY="$PREFIX/lib/libusb-1.0.a" 2>&1 | tee libfreenect2-configure.log
    grep -Eq "TurboJPEG +yes" libfreenect2-configure.log
    grep -Eq "VideoToolbox +no" libfreenect2-configure.log
    cmake --build libfreenect2-build-master --target freenect2 -j"$(sysctl -n hw.ncpu)"
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
# Fold libturbojpeg into the x86_64 libfreenect2 archive so the Xcode project
# links it without needing another library entry.
X86_FN2="$WORK/libfreenect2-x86_64-with-turbojpeg.a"
libtool -static -o "$X86_FN2" \
    "$(find "$WORK/libfreenect2-build-master" -name 'libfreenect2.a' | head -n1)" \
    "$PREFIX/lib/libturbojpeg.a"

merge "$LIBS/libusb_${LIBUSB_VER}.a"             "$PREFIX/lib/libusb-1.0.a"
merge "$LIBS/libfreenect_${LIBFREENECT_VER}.a"   "$X86_FN"
merge "$LIBS/libfreenect2_${LIBFREENECT2_VER}.a" "$X86_FN2"

echo "Universal libraries ready in $LIBS"
