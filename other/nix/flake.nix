{
  description = "IINA Advance – An even-more-modern fork of the modern video player for macOS.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      appName = "IINA Advance";

      systemNames = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      # Dictionary of { system name → package set }
      perSystemPackages = nixpkgs.lib.genAttrs systemNames (
        systemName:
        let
          pkgs = import nixpkgs {
            system = systemName;
          };

          ### Tools / Commands ###

          resign = pkgs.writeShellApplication {
            name = "iina-resign";
            runtimeInputs = [
              pkgs.findutils
              pkgs.coreutils
            ];
            text = ''
              set -euo pipefail
              app="$1"

              find "$app" -type d -print0 | xargs -0 chmod u+rwx
              find "$app" -type f -print0 | xargs -0 chmod u+rw
              find "$app/Contents/MacOS" -type f -perm -111 -print0 | xargs -0 chmod u+rw

              /usr/bin/codesign --force --deep --sign - "$app"
            '';
          };

          libTool = pkgs.stdenv.mkDerivation {
            pname = "iina-lib-tool";
            version = "1.0";
            propagatedBuildInputs = [ pkgs.python3 ];
            dontUnpack = true;
            installPhase = "install -Dm755 ${./lib_tool.py} $out/bin/iina-lib-tool";
          };

          # Pull system's xcode in
          xcode = pkgs.runCommand "system-xcode" { } ''
            mkdir -p "$out/bin"
            ln -sf /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "$out/bin/xcodebuild"
          '';

          ### Package Overrides ###

          libhwy = pkgs.libhwy.overrideAttrs (old: {
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DBUILD_SHARED_LIBS=ON" ];
          });

          ffmpeg =
            (pkgs.ffmpeg-headless.override {
              withDebug = false; # Build using debug options
              withStripping = true; # Strip symbols from the resulting binaries to reduce size
              withSmallDeps = true;

              withAss = true; # (Advanced) SubStation Alpha subtitle rendering
              withBluray = true;
              withDav1d = true; # AV1 decoder (focused on speed and correctness)
              withFontconfig = true;
              withFreetype = true;
              withHarfbuzz = true;
              withJxl = true;
              withGnutls = true;
              withOpenjpeg = true; # JPEG 2000 de/encoder
              withRubberband = true;
              withSoxr = true;
              withSvtav1 = true; # SVT-AV1 encoder, used for screenshots in AVIF format
              withTheora = true; # Theora video codec
              withVorbis = true; # Vorbis audio codec

              withX264 = false; # H.264 video encoder, not super useful for IINA (& adds >4 MB to app size)
              withX265 = false; # H.265 video encoder, not super useful for IINA (& adds >31 MB to app size)
              withAom = false; # AV1 video encoder, IINA prefers SVT-AV1 (better performance)
              withBs2b = false; # Bass to Binaural audio filter (uncommon)
              withCaca = false; # ASCII art video output, not useful for IINA
              withDvdnav = false;
              withDvdread = false;
              withMp3lame = false; # MP3 LAME audio codec encoder, not super useful for IINA
              withOpenapv = false; # APV video encoder, not very useful for IINA
              withOpenmpt = false; # Tracker music files decoder (various formats), not included in IINA historically
              withOpus = false; # Opus audio codec, not included in IINA historically
              withPlacebo = true;
              withRist = true; # RIST protocol support
              withSrt = false; # Secure Reliable Transport (SRT) protocol, not useful for IINA
              withSsh = false; # SFTP protocol support
              withVidStab = false; # Video stabilization filter, requires Linux
              withVmaf = false; # Video quality measurement tool, not useful for IINA
              withZmq = false; # ZeroMQ messaging library for FFmpeg streaming; not used by mpv or IINA
              withZvbi = false; # Teletext support, not useful for IINA

              # Unlikely to ever enable these
              withOpencl = false; # Vulkan predecessor, not supported on modern macOS
              withVdpau = false; # nVidia HW acceleration, not supported on modern macOS
              withXlib = false; # X11 support, no longer supported on modern OSes
              withXcb = false; # X11
              withXcbxfixes = false; # X11
              withXcbShape = false; # X11
              withXcbShm = false; # X11

              # Don't build docs; we don't use them
              withHtmlDoc = false;
              withManPages = false;
              withPodDoc = false;
              withTxtDoc = false;

              # Don't build executables; we only want the libs
              buildFfmpeg = false;
              buildFfplay = false;
              buildFfprobe = false;
              buildQtFaststart = false;

            }).overrideAttrs
              (old: {
                # Skip tests to speed up build
                doCheck = false;
              });

          # Override mpv with desired features support
          mpv =
            (pkgs.mpv-unwrapped.override {
              inherit ffmpeg;
              lua = pkgs.luajit;

              archiveSupport = true;
              bs2bSupport = false;
              bluraySupport = true;
              cacaSupport = false;
              cmsSupport = true;
              dvdnavSupport = false;
              javascriptSupport = true;
              openalSupport = false;
              rubberbandSupport = true;
              vapoursynthSupport = false;
              vulkanSupport = true;
              zimgSupport = true;

              # Disable Linux-only bits
              alsaSupport = false;
              jackaudioSupport = false;
              pipewireSupport = false;
              x11Support = false;
              waylandSupport = false;
              vaapiSupport = false;
              vdpauSupport = false;
              sdl2Support = false;
              cddaSupport = false;
              dvbinSupport = false;
              sixelSupport = false;
            }).overrideAttrs
              (
                finalAttrs: previousAttrs: {
                /*version = "git-unstable";
                src = pkgs.fetchFromGitHub {
                  owner = "sparky3387";
                  repo = "mpv";
                  rev = "master";
                  hash = "sha256-LAicqT7R832vIFULi+cyDi+XHKNK+03p8ncf5GHVEh4=";
                };*/
                  # Disable the building of man pages to speed up the build.
                  mesonFlags = previousAttrs.mesonFlags ++ [
                    "-Dmanpage-build=disabled"
                  ];
                  # Disabling building of man pages requires the package outputs be adjusted accordingly.
                  outputs = builtins.filter (x: x != "man") previousAttrs.outputs;
                  patches =
                    [ ]
                    # If needed include the fix for IINA issue #5956, the mpv regression described in mpv
                    # issue #17436 and fixed in mpv PR #17448. The fix is expected to be included in
                    # mpv 0.42.0.
                    ++
                      pkgs.lib.optionals
                        (
                          pkgs.lib.versionAtLeast finalAttrs.version "v0.40.0"
                          && pkgs.lib.versionOlder finalAttrs.version "v0.42.0"
                        )
                        [
                          (pkgs.fetchpatch2 {
                            url = "https://github.com/mpv-player/mpv/pull/17448.patch";
                            hash = "sha256-kXnlu8SJ/GEnFljnXK4ri6CrgDBXvOTjnQo3jdPAbSA=";
                          })
                        ];
                }
              ); # END mpv

          ### Dep Aggregations ###

          # Collect include deps (header files) as per readme.md
          depsInclude = pkgs.linkFarm "iina-deps-inc" [
            {
              name = "mpv";
              path = "${pkgs.lib.getDev mpv}/include/mpv";
            }
            {
              name = "libavcodec";
              path = "${pkgs.lib.getDev ffmpeg}/include/libavcodec";
            }
            {
              name = "libavdevice";
              path = "${pkgs.lib.getDev ffmpeg}/include/libavdevice";
            }
            {
              name = "libavfilter";
              path = "${pkgs.lib.getDev ffmpeg}/include/libavfilter";
            }
            {
              name = "libavformat";
              path = "${pkgs.lib.getDev ffmpeg}/include/libavformat";
            }
            {
              name = "libavutil";
              path = "${pkgs.lib.getDev ffmpeg}/include/libavutil";
            }
            {
              name = "libswresample";
              path = "${pkgs.lib.getDev ffmpeg}/include/libswresample";
            }
            {
              name = "libswscale";
              path = "${pkgs.lib.getDev ffmpeg}/include/libswscale";
            }
          ]; # END depsInclude

          # Collect lib deps as per readme.md
          depsLib = pkgs.linkFarm "iina-deps-lib" (
            pkgs.lib.flatten (
              map
                (
                  pkg:
                  let
                    libdir = "${pkgs.lib.getLib pkg}/lib";
                  in
                  builtins.map (file: {
                    name = baseNameOf file;
                    path = "${libdir}/${file}";
                  }) (builtins.attrNames (builtins.readDir libdir))
                )
                [
                  ffmpeg
                  libhwy
                  mpv
                  pkgs.brotli # Brotli compression. Used for ass, fontconfig, bluray, & more
                  pkgs.dav1d # AV1 video decoder
                  pkgs.fontconfig # Font configuration library
                  pkgs.freetype # FreeType font rendering engine
                  pkgs.fribidi # Hebrew and Arabic support
                  pkgs.gettext # Internationalization library
                  pkgs.glib # GTK GLib utility library. Required by harfbuzz
                  pkgs.gmp # Provides arbitrary precision arithmetic. Required by several libs
                  pkgs.gnutls # TLS support, needed for network streams
                  pkgs.graphite2 # Compiles Graphite-enabled fonts. Used by harfbuzz
                  pkgs.harfbuzz # Text shaping engine. Used by avdevice, avfilter, ass
                  pkgs.haskellPackages.character-ps
                  pkgs.haskellPackages.indexed-traversable
                  pkgs.haskellPackages.integer-conversion
                  pkgs.haskellPackages.network-uri
                  pkgs.haskellPackages.semialign
                  pkgs.haskellPackages.text-iso8601
                  pkgs.haskellPackages.witherable
                  pkgs.lcms2 # Little CMS color management lib. Required by placebo, jxl
                  pkgs.libarchive # Archive support
                  pkgs.libass # ASS subtitle renderer
                  pkgs.libb2 # BLAKE2 hashing library
                  pkgs.libbluray # Blu-ray support
                  pkgs.libidn2 # Converts between ASCII & UTF domain names. Used by gnutls
                  pkgs.libjpeg_turbo # Needed to provide libjpeg
                  pkgs.libjxl # JPEG-XL support
                  pkgs.libplacebo # Required by mpv
                  pkgs.libpng # PNG image format support
                  pkgs.libsamplerate # Sample Rate Converter for audio
                  pkgs.libtasn1 # ASN.1 library used by GnuTLS, p11-kit
                  pkgs.libuchardet # Character encoding detection library
                  pkgs.libunibreak # Unicode line breaking & word/grapheme breaking
                  pkgs.libunistring # Unicode string handling
                  pkgs.libwebp # WebP image de/encoder
                  pkgs.luajit # Lua Just-In-Time compiler. Required by mpv
                  pkgs.lz4 # LZ4 compression. Used by libarchive
                  pkgs.moltenvk # Vulkan support for macOS. Required by libplacebo
                  pkgs.mujs # JavaScript engine. Needed for mpv's JS support
                  pkgs.nettle # GnuTLS dependency (cryptographic algorithms)
                  pkgs.pcre2 # (Per-compatible) Regular expression pattern matching
                  pkgs.rubberband # Enables FFmpeg to perform audio tempo & pitch modifications
                  pkgs.shaderc # Referenced by libplacebo, even though it requires Vulkan which IINA doesn't use
                  pkgs.snappy # Snappy compression
                  pkgs.soxr # SoX Resampler, needed for high-quality audio resampling
                  pkgs.speex # Used by avcodec, avdevice, avfilter, avformat
                  pkgs.xz # LZMA2 compression, needed by libarchive
                  pkgs.zimg # Image scaling & colorspace conversion library, needed by mpv
                  pkgs.zstd # Needed by libarchive

                  # Indirect libs
                  pkgs.libcxx # C standard library
                  pkgs.libdovi # Dolby Vision, needed by libplacebo
                  pkgs.libvorbis # Vorbis audio codec
                  pkgs.openjpeg # JPEG 2000 de/encoder
                ]
            ) # END pkgs.lib.flatten
          ); # END depsLib

          # Collect SwiftPM deps as separate derivation for them to be cached
          spmDeps = pkgs.stdenv.mkDerivation {
            pname = "iina-spm-deps";
            version = "${self.shortRev or self.dirtyShortRev}";

            # Only include SwiftPM-related files as input
            src = pkgs.lib.cleanSourceWith {
              src = ./../..;
              filter =
                path: type:
                let
                  relPath = pkgs.lib.removePrefix (toString ./../.. + "/") (toString path);
                in
                pkgs.lib.hasSuffix "Package.resolved" relPath
                || pkgs.lib.hasSuffix "Package.swift" relPath
                || pkgs.lib.hasPrefix "iina.xcodeproj" relPath;
            };

            dontFixup = true;

            nativeBuildInputs = [
              xcode
              pkgs.findutils
            ];

            buildPhase = ''
              export HOME=$PWD/.home
              export CFFIXED_USER_HOME="$HOME"
              export __XPC_CFFIXED_USER_HOME="$HOME"
              export TMPDIR="$PWD/.tmp"; mkdir -p "$TMPDIR"
              export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

              APPLE_BIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
              export PATH="${pkgs.findutils}/bin:$APPLE_BIN:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:$PATH"

              export TOOLCHAINS=XcodeDefault
              export SDKROOT=macosx

              if [ "$systemName" == "aarch64-darwin" ]; then
                export XCODE_BUILD_DESTINATION='platform=macOS,arch=arm64'
              else
                export XCODE_BUILD_DESTINATION='platform=macOS,arch=x86_64'
              fi

              mkdir -p .spm .spm-cache build

              xcodebuild \
                -workspace iina.xcodeproj/project.xcworkspace \
                -scheme iina \
                -destination "$XCODE_BUILD_DESTINATION" \
                -resolvePackageDependencies \
                -derivedDataPath "$PWD/build" \
                -clonedSourcePackagesDirPath "$PWD/.spm" \
                -packageCachePath "$PWD/.spm-cache" \
                -disablePackageRepositoryCache \
                -IDEPackageSupportDisableManifestSandbox=YES \
                -IDEPackageSupportDisablePluginExecutionSandbox=YES \
                ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
                SWIFT_ENABLE_EXPLICIT_MODULES=NO
            '';

            # Copy everything — keep full structure (SPM state, caches, workspace, etc.)
            installPhase = ''
              mkdir -p $out
              cp -R . $out/
            '';
          }; # END spmDeps

          packages = {

            iina = pkgs.stdenv.mkDerivation {
              pname = "iina";
              version = "${self.shortRev or self.dirtyShortRev}";

              src = pkgs.nix-gitignore.gitignoreSource [ "flake.nix" "flake.lock" ] ./../..;

              strictDeps = true;

              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.findutils
                xcode
                libTool
                pkgs.rsync
                pkgs.gnused
                spmDeps
              ];

              buildPhase = ''
                echo "[${systemName}] 🔧 Setting up build environment for ${appName}"
                git_rev="${self.rev or self.dirtyRev}"
                # Nix flakes cannot currently access branch info. Doing so may violate the stated goal of maximum
                # reproducibility, as the same git revision can be associated with an arbitrary number of branches.
                # Just use a placeholder for now:
                git_branch="<nix-build>"
                echo "Git branch: $git_branch, revision: $git_rev"
                export HOME=$PWD/.home
                export CFFIXED_USER_HOME="$HOME"
                export __XPC_CFFIXED_USER_HOME="$HOME"
                export TMPDIR="$PWD/.tmp"; mkdir -p "$TMPDIR"
                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

                APPLE_BIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
                # For nixos-26.05+: need to explicitly use the GNU findutils version of find, as the system find (from macOS) does not support -print0
                # and will fail with "find: -print0: unknown primary or operator" in fixup phase
                export PATH="${pkgs.findutils}/bin:$APPLE_BIN:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:$PATH"

                if [ "$systemName" == "aarch64-darwin" ]; then
                  export XCODE_BUILD_DESTINATION='platform=macOS,arch=arm64'
                else
                  export XCODE_BUILD_DESTINATION='platform=macOS,arch=x86_64'
                fi

                unset CC CXX LD AR RANLIB NM STRIP OBJCOPY \
                  CFLAGS CXXFLAGS LDFLAGS SDKROOT CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH \
                  NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK PKG_CONFIG_PATH

                export TOOLCHAINS=XcodeDefault
                export SDKROOT=macosx

                echo "Using $TOOLCHAINS toolchain"
                echo "Using $SDKROOT sdk"

                echo "[${systemName}] 📦 Copying external deps"
                mkdir -p deps
                rm -rf deps/include deps/lib

                mkdir -p deps/include deps/lib deps/executable
                cp -RL "${depsInclude}/" deps/include
                cp -RLv "${depsLib}/" deps/lib

                echo "[${systemName}] 📦 Copying SPM deps"
                rsync -a "${spmDeps}/" ./
                chmod -R u+rwx,g+rx,o+rx .

                echo "[${systemName}] 📦 Canonicalizing libs"
                ${libTool}/bin/iina-lib-tool --canonicalize --prune "./deps/lib" "./deps/executable"

                # Rewrite SwiftPM workspace-state.json to fix absolute paths
                if [ -f .spm/workspace-state.json ]; then
                  old_prefix=$(grep -Eo "/nix/var/nix/builds/nix-[^/]+/source" .spm/workspace-state.json | head -n1)
                  echo "Patching workspace-state.json: replacing $old_prefix → $PWD"
                  sed -i -E "s|$old_prefix|$PWD|g" .spm/workspace-state.json
                fi

                # Build IINA Advance (single-arch)
                echo "[${systemName}] 🔨 Building ${appName}"
                xcodebuild \
                  -workspace iina.xcodeproj/project.xcworkspace \
                  -scheme iina \
                  -destination "$XCODE_BUILD_DESTINATION" \
                  -configuration Release \
                  -sdk macosx \
                  -skipPackagePluginValidation \
                  -derivedDataPath "$PWD/build" \
                  -clonedSourcePackagesDirPath "$PWD/.spm" \
                  -packageCachePath "$PWD/.spm-cache" \
                  -disablePackageRepositoryCache \
                  -disableAutomaticPackageResolution \
                  -onlyUsePackageVersionsFromResolvedFile \
                  -IDEPackageSupportDisableManifestSandbox=YES \
                  -IDEPackageSupportDisablePluginExecutionSandbox=YES \
                  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
                  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
                  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
              '';

              installPhase = ''
                mkdir -p "$out/Applications"
                cp -R "build/Build/Products/Release/${appName}.app" "$out/Applications/"
              '';

              preFixup = ''
                export PATH=${pkgs.coreutils}/bin:${pkgs.findutils}/bin:$PATH
              '';

              postFixup = ''
                app="$out/Applications/${appName}.app"
                macos="$app/Contents/MacOS"
                frameworks="$app/Contents/Frameworks"
                plist="$app/Contents/Info.plist"

                mkdir -p "$frameworks"

                echo "[${systemName}] 📦 Deep-bundling dynamic dependencies into ${appName}.app"
                ${libTool}/bin/iina-lib-tool --canonicalize "$frameworks" "$macos"

                echo "[${systemName}] ✏️ Setting up environment variables"

                /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict'                                       "$plist" 2>/dev/null || true
                /usr/libexec/PlistBuddy -c 'Add :LSEnvironment:IINA_EXECUTABLE string "@executable_path"'  "$plist" 2>/dev/null || true
                /usr/libexec/PlistBuddy -c 'Set :LSEnvironment:IINA_EXECUTABLE        "@executable_path"'  "$plist"
                # Overwrite Git info from build (which were set to placeholders because Xcode script could not determine them at build time)
                /usr/libexec/PlistBuddy -c "Set :com.iina-advance.build.commit        $git_rev"            "$plist"
                /usr/libexec/PlistBuddy -c "Set :com.iina-advance.build.branch        $git_branch"         "$plist"
              '';
            }; # END iina

            # --- IINA Universal ---
            iina-universal = pkgs.stdenv.mkDerivation {
              pname = "iina-universal";
              version = "${self.shortRev or self.dirtyShortRev}";

              nativeBuildInputs = [
                libTool
                pkgs.rsync
                pkgs.coreutils
                pkgs.findutils
              ];

              buildCommand = ''
                app="$out/Applications/${appName}.app"
                frameworks="$app/Contents/Frameworks"

                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
                APPLE_BIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
                export PATH="$APPLE_BIN:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:$PATH"

                echo "📦 Combining universal ${appName}.app"

                mkdir -p "$out/Applications"
                # copy the contents of the source app into the target dir
                ${pkgs.rsync}/bin/rsync -a "${builtins.elemAt self.archApps 0}/Applications/${appName}.app/" "$app/"
                chmod -R u+w "$app"

                archroot0="${builtins.elemAt self.archApps 0}/Applications/${appName}.app"
                archroot1="${builtins.elemAt self.archApps 1}/Applications/${appName}.app"

                ${libTool}/bin/iina-lib-tool --merge-architectures --canonicalize "$frameworks" "$app/Contents/MacOS" \
                  --archroot0 "$archroot0" --archroot1 "$archroot1"

                echo "🔏 Re-signing ${appName}.app..."
                ${resign}/bin/iina-resign "$app"

                echo "[${systemName}] 📦 Copying include dir"
                mkdir -p "$out/include"
                cp -RL ${depsInclude}/. $out/include

                app_real=$(realpath "$app" 2>/dev/null || echo "$app")
                echo "✅✅ Done! Universal ${appName}.app is ready at $app_real"
              '';

              preFixup = ''
                export PATH=${pkgs.coreutils}/bin:${pkgs.findutils}/bin:$PATH
              '';
            }; # END iina-universal

            default = packages.iina-universal;
          }; # END packages

        in
        packages
      ); # END perSystemPackages
    in
    {
      inherit systemNames;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
      packages = nixpkgs.lib.genAttrs systemNames (systemName: (perSystemPackages.${systemName}));
      archApps = builtins.map (systemName: self.packages.${systemName}.iina) systemNames;
    };
}
