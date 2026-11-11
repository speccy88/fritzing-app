# Build Fritzing for Apple Silicon

Run from a clean Git checkout of the revision to package. The build requires
Apple Silicon, Xcode with the macOS SDK selected, Python 3.9 or newer with
`venv` and `pip`, CMake, and Ninja. Xcode's command-line tools provide the
compiler, signing tools, and native libraries.

```sh
./tools/deploy_fritzing_mac.sh
```

The script downloads Qt 6.10.3 and checks each dependency source archive against
`sources.lock`. It compiles the native dependencies, builds Fritzing in a
separate checkout, and generates the SQLite parts database from the pinned
Fritzing parts commit. The Qt runtime, ngspice 42 with XSPICE models, parts,
examples, translations, and license notices are included in the app. The app's
`Contents/Resources/BuildInfo.txt` records the source and parts commits.

The default build cache is `~/Library/Caches/FritzingBuild` and the default
output directory is `~/Downloads`. Use `FRITZING_BUILD_ROOT` to select a separate
cache, for example when changing SDKs, and `FRITZING_JOBS` to set the number
of build jobs. Set `FRITZING_OUTPUT_DIR` to change where the three output files
are written and `FRITZING_PACKAGE_NAME` to set their shared base name. To use
an existing Qt 6.10.3 macOS SDK, set `FRITZING_QT_PREFIX` to its installation
prefix with the Qt Serial Port module and Qt command-line tools available.

The three output files are an ad-hoc-signed app on a drag-to-Applications disk
image, an archive of dependency sources and notices, and a SHA-256 checksum file.
The app sources and this script are available in the Git revision recorded in
the build. The package uses macOS 13 as its deployment target and a fixed parts
snapshot. To refresh the parts library, update the pinned commit and build again
in a fresh cache.

Mount the disk image and drag Fritzing into Applications. A build downloaded
from the internet is subject to macOS Gatekeeper because it is ad-hoc signed
and unnotarized.
