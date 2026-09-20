#!/bin/bash
# Сборка libdave (Discord DAVE, сквозное шифрование голоса) для iOS arm64 в Vendor/dave.
# Результат: Vendor/dave/lib/*.a и Vendor/dave/include.
set -euo pipefail

ROOT="$(pwd)"
OUT="$ROOT/Vendor/dave"
TMP="${RUNNER_TEMP:-/tmp}"
WORK="$TMP/dave-work"
LOG="$TMP/dave-build.log"
LIBDAVE_REF="5cb8952a8e6f08071d8c24edae2496199d7a9197"

exec > >(tee "$LOG") 2>&1

on_error() {
  echo ""
  echo "=== ОШИБКА СБОРКИ libdave ==="
  if [ -d "$WORK/libdave/cpp/vcpkg/buildtrees" ]; then
    for f in $(ls -t "$WORK"/libdave/cpp/vcpkg/buildtrees/*/*.log 2>/dev/null | head -4); do
      echo "--- $f"
      tail -n 40 "$f"
    done
  fi
  rm -rf "$OUT"
}
trap on_error ERR

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT/lib" "$OUT/include"

cd "$WORK"
git clone https://github.com/discord/libdave.git
cd libdave
git checkout "$LIBDAVE_REF"
git submodule update --init --recursive
cd cpp

# Свежий Clang может ругаться на код, который у Discord собирается. Предупреждения не должны ломать сборку.
sed -i '' 's/ -Werror//g' CMakeLists.txt

env -u VCPKG_ROOT ./vcpkg/bootstrap-vcpkg.sh -disableMetrics

mkdir -p triplets
cat > triplets/arm64-ios-dave.cmake <<'TRIPLET'
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_SYSROOT iphoneos)
set(VCPKG_OSX_DEPLOYMENT_TARGET 18.0)
set(VCPKG_BUILD_TYPE release)
TRIPLET

env -u VCPKG_ROOT cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DVCPKG_MANIFEST_DIR="$PWD/vcpkg-alts/openssl_3" \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/vcpkg/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_OVERLAY_TRIPLETS="$PWD/triplets" \
  -DVCPKG_TARGET_TRIPLET=arm64-ios-dave \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DBUILD_SHARED_LIBS=OFF \
  -DTESTING=OFF \
  -DPERSISTENT_KEYS=OFF

cmake --build build --target libdave --config Release -j "$(sysctl -n hw.ncpu)"

# Забираем результат: сама libdave и все её зависимости (mlspp, OpenSSL и т.д.)
DAVE_LIB=$(find build -maxdepth 2 -name 'libdave.a' | head -1)
[ -n "$DAVE_LIB" ] || { echo "libdave.a не найден"; exit 1; }
cp "$DAVE_LIB" "$OUT/lib/libdave.a"

MLSPP_LIB=$(find build -name 'libmlspp.a' | head -1)
[ -n "$MLSPP_LIB" ] || { echo "libmlspp.a не найден"; exit 1; }
LIBDIR=$(dirname "$MLSPP_LIB")
cp "$LIBDIR"/*.a "$OUT/lib/"
rm -f "$OUT"/lib/libgtest* "$OUT"/lib/libgmock* "$OUT"/lib/libCatch* "$OUT"/lib/libcatch*

cp -R includes/. "$OUT/include/"

echo ""
echo "=== libdave собрана ==="
ls -la "$OUT/lib"
lipo -info "$OUT/lib/libdave.a" || true
