#!/bin/bash
set -euo pipefail
umask 022

repo="$(cd "$(dirname "$0")/.." && pwd)"
source_sha="$(git -C "$repo" rev-parse HEAD)"
qt_version=6.10.3
parts_sha=27535f2fd02097be9bed229b75aa8e9be282a4a0
parts_url=https://github.com/fritzing/fritzing-parts.git
deployment_target=13.0
cache="${FRITZING_BUILD_ROOT:-$HOME/Library/Caches/FritzingBuild}"
output="${FRITZING_OUTPUT_DIR:-$HOME/Downloads}"
package="${FRITZING_PACKAGE_NAME:-Fritzing-1.0.8-${source_sha:0:8}-arm64}"
jobs="${FRITZING_JOBS:-$(sysctl -n hw.ncpu)}"
downloads="$cache/downloads"
dependency_sources="$cache/dep-src"
dependency_builds="$cache/dep-build"
dependencies="$cache/deps"
qt="${FRITZING_QT_PREFIX:-$cache/Qt/$qt_version/macos}"
parts="$cache/parts-checkout"
work="$cache/builds/$source_sha"
source="$work/fritzing-app"
lock="$repo/tools/macos/sources.lock"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -m)" == arm64 ]] || die 'Run this script natively on Apple Silicon.'
[[ "$cache" == /* && "$cache" != *[[:space:]]* ]] || die 'Use an absolute build root without whitespace.'
[[ "$output" == /* && "$package" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Use an absolute output directory and a simple package name.'
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die 'FRITZING_JOBS must be a positive integer.'
git -C "$repo" diff --quiet HEAD -- || die 'Commit tracked changes before packaging.'
for tool in python3 cmake ninja; do
    command -v "$tool" >/dev/null || die "Install $tool before building."
done
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$downloads" "$dependency_sources" "$dependency_builds" "$dependencies" "$work" "$output"
[[ ! -e "$output/$package.dmg" ]] || die "Output already exists at $output/$package.dmg."

step 'Check the pinned source archives'
archives=()
while read -r digest archive url; do
    [[ -n "$digest" && "$digest" != \#* ]] || continue
    if [[ ! -f "$downloads/$archive" ]]; then
        /usr/bin/curl -fLsS --retry 2 --connect-timeout 15 -o "$downloads/$archive.partial" "$url"
        mv "$downloads/$archive.partial" "$downloads/$archive"
    fi
    (cd "$downloads" && printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -)
    archives+=("$archive")
done < "$lock"

if [[ ! -x "$qt/bin/qmake" || ! -x "$qt/bin/lrelease" || ! -x "$qt/bin/macdeployqt" ||
      ! -f "$qt/mkspecs/modules/qt_lib_serialport.pri" ]]; then
    step "Install Qt $qt_version in the build cache"
    [[ -z "${FRITZING_QT_PREFIX:-}" ]] || die "The Qt SDK at $qt is incomplete."
    python3 -m venv "$cache/aqt-env"
    "$cache/aqt-env/bin/python" -m pip install --disable-pip-version-check aqtinstall==3.3.0
    (cd "$cache" && "$cache/aqt-env/bin/aqt" install-qt mac desktop "$qt_version" clang_64 -m qtserialport -O "$cache/Qt")
fi
[[ "$("$qt/bin/qmake" -query QT_VERSION)" == "$qt_version" ]] || die "Qt $qt_version is required."

unpack() {
    local archive="$1" destination="$2" strip="$3"
    if [[ ! -f "$destination/.fritzing-extracted" ]]; then
        mkdir -p "$destination"
        /usr/bin/tar -xf "$downloads/$archive" --strip-components="$strip" -C "$destination"
        touch "$destination/.fritzing-extracted"
    fi
}

cmake_dependency() {
    local name="$1" source_dir="$2" prefix="$3"
    shift 3
    cmake -S "$source_dir" -B "$dependency_builds/$name" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_INSTALL_PREFIX="$prefix" "$@"
    cmake --build "$dependency_builds/$name" --parallel "$jobs"
    cmake --install "$dependency_builds/$name"
}

step 'Build native dependencies'
libgit=libgit2-1.7.1
quazip="quazip-$qt_version-1.4intuisphere"
clipper=Clipper1-6.4.2
spice=ngspice-42
unpack libgit2.tar.gz "$dependency_sources/$libgit" 1
unpack quazip.tar.gz "$dependency_sources/$quazip" 1
unpack clipper.zip "$dependency_sources/$clipper" 0
unpack ngspice.tar.gz "$dependency_sources/$spice" 1
unpack svgpp.tar.gz "$dependency_sources/svgpp-1.3.1" 1
unpack boost.tar.bz2 "$dependency_sources/boost_1_85_0" 1

if [[ ! -f "$dependencies/$libgit/lib/libgit2.a" ]]; then
    cmake_dependency libgit2 "$dependency_sources/$libgit" "$dependencies/$libgit" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF \
        -DUSE_SSH=OFF -DUSE_HTTPS=SecureTransport -DUSE_HTTP_PARSER=builtin -DREGEX_BACKEND=builtin
fi
if [[ ! -f "$dependencies/$quazip/lib/libquazip1-qt6.dylib" ]]; then
    cmake_dependency quazip "$dependency_sources/$quazip" "$dependencies/$quazip" \
        -DCMAKE_PREFIX_PATH="$qt" -DQUAZIP_QT_MAJOR_VERSION=6 -DBUILD_SHARED_LIBS=ON -DQUAZIP_BZIP2=OFF
fi
if [[ ! -f "$dependencies/$clipper/lib/libpolyclipping.a" ]]; then
    clipper_source="$dependency_sources/$clipper/cpp"
    clipper_prefix="$dependencies/$clipper"
    mkdir -p "$clipper_prefix/include/polyclipping" "$clipper_prefix/lib"
    xcrun clang++ -arch arm64 -isysroot "$sdk" -mmacosx-version-min="$deployment_target" -O2 \
        -c "$clipper_source/clipper.cpp" -o "$clipper_prefix/clipper.o"
    xcrun ar rcs "$clipper_prefix/lib/libpolyclipping.a" "$clipper_prefix/clipper.o"
    cp "$clipper_source/clipper.hpp" "$clipper_prefix/include/polyclipping/"
fi
if [[ ! -f "$dependencies/$spice/lib/ngspice/analog.cm" ]]; then
    mkdir -p "$dependency_builds/ngspice"
    (
        cd "$dependency_builds/ngspice"
        export MACOSX_DEPLOYMENT_TARGET="$deployment_target" SDKROOT="$sdk"
        CC="$(xcrun --find clang)"
        CXX="$(xcrun --find clang++)"
        export CC CXX
        export CFLAGS='-O2 -arch arm64 -Wno-error=incompatible-function-pointer-types'
        export CXXFLAGS='-O2 -arch arm64'
        # ngspice 42's bundled cppduals predates this Clang diagnostic.
        if "$CXX" -Werror=unknown-warning-option -Wno-invalid-specialization -fsyntax-only -x c++ /dev/null; then
            CXXFLAGS+=' -Wno-invalid-specialization'
        fi
        "$dependency_sources/$spice/configure" --prefix="$dependencies/$spice" \
            --with-ngshared --enable-xspice --disable-openmp --disable-debug
        /usr/bin/make -j"$jobs"
        /usr/bin/make install
    )
fi

step "Build Fritzing at $source_sha"
if [[ ! -d "$source/.git" ]]; then
    git -c init.templateDir= clone --shared --no-checkout "$repo" "$source"
    git -C "$source" -c advice.detachedHead=false checkout --detach "$source_sha"
fi
for dependency in "$libgit" "$quazip" "$clipper" "$spice"; do
    [[ -L "$work/$dependency" ]] || ln -s "$dependencies/$dependency" "$work/$dependency"
done
[[ -L "$work/svgpp-1.3.1" ]] || ln -s "$dependency_sources/svgpp-1.3.1" "$work/svgpp-1.3.1"
(
    cd "$source"
    # Qt 6.10 headers need the ARM intrinsics declaration with Apple Clang 21.
    env -u CI "$qt/bin/qmake" phoenix.pro "boost_root=$dependency_sources/boost_1_85_0" \
        -after QMAKE_APPLE_DEVICE_ARCHS=arm64 "QMAKE_MACOSX_DEPLOYMENT_TARGET=$deployment_target" \
        "QMAKE_CXXFLAGS+=-include arm_acle.h"
    /usr/bin/make -j"$jobs" release
)

step "Stage the app and build the parts database at $parts_sha"
if [[ ! -d "$parts/.git" ]]; then
    git init --template= "$parts"
    git -C "$parts" remote add origin "$parts_url"
    git -C "$parts" fetch --depth 1 origin "$parts_sha"
    git -C "$parts" checkout -b develop FETCH_HEAD
fi
[[ "$(git -C "$parts" rev-parse HEAD)" == "$parts_sha" ]] || die 'The cached parts checkout has a different revision.'
stage="$(mktemp -d "$work/package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/disk" "$stage/home" "$stage/sources"
app="$stage/disk/Fritzing.app"
ditto "$work/release64/Fritzing.app" "$app"
resources="$app/Contents/Resources"
plugins="$app/Contents/PlugIns"
mkdir -p "$resources/translations" "$resources/licenses" "$plugins"
cp -R "$source/help" "$source/sketches" "$resources/"
cp -R "$source/translations/syntax" "$resources/translations/"
for translation in "$source"/translations/*.ts; do
    "$qt/bin/lrelease" "$translation" -qm "$resources/translations/$(basename "${translation%.ts}").qm"
done
find "$resources/translations" -name '*.qm' -size -128c -delete
cp "$source"/LICENSE* "$resources/licenses/"
cp "$dependency_sources/$libgit/COPYING" "$resources/licenses/libgit2.txt"
cp "$dependency_sources/$quazip/COPYING" "$resources/licenses/QuaZip.txt"
cp "$dependency_sources/$clipper/License.txt" "$resources/licenses/Clipper.txt"
cp "$dependency_sources/$spice/COPYING" "$resources/licenses/ngspice.txt"
cp "$dependency_sources/svgpp-1.3.1/LICENSE_1_0.txt" "$resources/licenses/SVGpp.txt"
for module in qtbase qtsvg qtserialport; do
    mkdir "$resources/licenses/$module"
    /usr/bin/tar -xf "$downloads/$module-everywhere-src-$qt_version.tar.xz" \
        --strip-components=2 -C "$resources/licenses/$module" "$module-everywhere-src-$qt_version/LICENSES"
    cp "$qt/sbom/$module-$qt_version.spdx" "$resources/licenses/$module/"
done
git -c init.templateDir= clone --no-hardlinks "$parts" "$resources/fritzing-parts"
git -C "$resources/fritzing-parts" remote set-url origin "$parts_url"
db="$resources/fritzing-parts/parts.db"
env HOME="$stage/home" CFFIXED_USER_HOME="$stage/home" QT_QPA_PLATFORM=offscreen \
    QT_PLUGIN_PATH="$qt/plugins" "$app/Contents/MacOS/Fritzing" -db "$db"
[[ "$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;')" == ok ]] || die 'The parts database failed its integrity check.'
[[ "$(sqlite3 -readonly "$db" 'SELECT sha FROM lastcommit WHERE id = 0;')" == "$parts_sha" ]] || die 'The parts database has a different revision.'
part_count="$(sqlite3 -readonly "$db" 'SELECT count(*) FROM parts;')"
[[ "$part_count" -gt 0 ]] || die 'The parts database is empty.'
printf 'Application source %s\nParts source %s\nParts indexed %s\nQt %s\n' \
    "$source_sha" "$parts_sha" "$part_count" "$qt_version" > "$resources/BuildInfo.txt"

step 'Deploy the runtime and sign the bundle'
"$qt/bin/macdeployqt" "$app" -no-strip -verbose=2 \
    "-libpath=$dependencies/$quazip/lib" "-libpath=$qt/lib"
# Fritzing uses SQLite and the native macOS TLS backend. The other database
# drivers and the OpenSSL backend can pull in software outside the bundle.
find "$plugins/sqldrivers" -type f ! -name libqsqlite.dylib -delete
rm -f "$plugins/tls/libqopensslbackend.dylib"
for plugin in platforms/libqcocoa.dylib sqldrivers/libqsqlite.dylib tls/libqsecuretransportbackend.dylib; do
    [[ -f "$plugins/$plugin" ]] || die "Required Qt plugin is missing: $plugin."
done
mkdir -p "$plugins/ngspice"
cp -L "$dependencies/$spice/lib/libngspice.0.dylib" "$plugins/"
cp -L "$dependencies/$spice/lib/ngspice/"*.cm "$plugins/ngspice/"
install_name_tool -id @loader_path/libngspice.0.dylib "$plugins/libngspice.0.dylib"
for model in "$plugins/ngspice/"*.cm; do
    if [[ "$(otool -D "$model" | wc -l)" -gt 1 ]]; then
        install_name_tool -id "@loader_path/$(basename "$model")" "$model"
    fi
done
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $deployment_target" "$app/Contents/Info.plist"
python3 "$repo/tools/macos/verify_bundle.py" --strip-build-rpaths "$app"
while IFS= read -r -d '' binary; do
    if [[ "$(file -b "$binary")" == *Mach-O* ]]; then
        codesign --force --sign - --timestamp=none "$binary"
    fi
done < <(find "$app/Contents/Frameworks" "$plugins" -type f -print0)
while IFS= read -r -d '' framework; do
    codesign --force --sign - --timestamp=none "$framework"
done < <(find "$app/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"

step 'Create the disk image and dependency source archive'
ln -s /Applications "$stage/disk/Applications"
hdiutil create -volname 'Fritzing 1.0.8' -srcfolder "$stage/disk" -format UDZO "$stage/$package.dmg"
hdiutil verify "$stage/$package.dmg"

cp "$lock" "$stage/sources/sources.lock"
cp "$resources/BuildInfo.txt" "$stage/sources/BuildInfo.txt"
cp -R "$resources/licenses" "$stage/sources/"
for archive in "${archives[@]}"; do
    ln "$downloads/$archive" "$stage/sources/$archive"
done
git -C "$parts" archive --prefix=fritzing-parts/ "$parts_sha" | /usr/bin/gzip -n > "$stage/sources/fritzing-parts-$parts_sha.tar.gz"
/usr/bin/tar -cf "$stage/$package-dependency-sources.tar" -C "$stage/sources" .
(
    cd "$stage"
    shasum -a 256 "$package.dmg" "$package-dependency-sources.tar" > "$package.sha256"
)
for extension in .dmg -dependency-sources.tar .sha256; do
    mv "$stage/$package$extension" "$output/"
done
printf '\nDisk image and source archive saved in %s\n' "$output"
