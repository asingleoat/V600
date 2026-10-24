{
  description = "CerealGrain: film scanning and processing for the Epson V600";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
      # The build reads the commit from git; the Nix sandbox has no .git, so
      # packages pass the flake's own.
      version = self.shortRev or self.dirtyShortRev or "unknown";
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs { inherit system; }));
      nuklearPackage = pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "nuklear";
          version = "4.12.7";
          src = pkgs.fetchFromGitHub {
            owner = "Immediate-Mode-UI";
            repo = "Nuklear";
            rev = "4.12.7";
            hash = "sha256-EE76hj40BwRPRa/+m2Uhgr5pqChrkifwMfGw0DZdxug=";
          };
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/include" "$out/lib/pkgconfig"
            cp nuklear.h "$out/include/"
            cat > "$out/lib/pkgconfig/nuklear.pc" <<EOF
prefix=$out
includedir=$out/include

Name: nuklear
Description: Single-header immediate-mode GUI library
Version: 4.12.7
Cflags: -I$out/include
EOF
            runHook postInstall
          '';
        };
      cleanSource = pkgs:
        pkgs.lib.cleanSourceWith {
          src = self;
          filter = path: type:
            let
              rel = pkgs.lib.removePrefix ((toString self) + "/") (toString path);
              top = builtins.head (pkgs.lib.splitString "/" rel);
              base = baseNameOf path;
              inFixtureTree = pkgs.lib.hasPrefix "test/fixtures/" rel;
              generatedDir = builtins.elem top [
                ".zig-cache"
                "frames"
                "firmware"
                "frames-archive"
                "scans"
                "workspace"
                "zig-out"
              ];
              generatedFile =
                base == "scanner.toml" ||
                base == "processing.toml" ||
                base == "libesintA1_lut.so" ||
                base == "libesintA1_unified.so" ||
                (!inFixtureTree && (
                  pkgs.lib.hasSuffix ".log" base ||
                  pkgs.lib.hasSuffix ".tmp" base ||
                  pkgs.lib.hasSuffix ".pcapng" base ||
                  pkgs.lib.hasSuffix ".tif" base ||
                  pkgs.lib.hasSuffix ".tiff" base ||
                  pkgs.lib.hasSuffix ".png" base ||
                  pkgs.lib.hasSuffix ".jpg" base ||
                  pkgs.lib.hasSuffix ".pnm" base
                ));
            in
            !(generatedDir || generatedFile);
        };
      # A fully static CLI for any x86-64 Linux: musl, every C library
      # linked in, for x86-64-v3 CPUs (Haswell and later).
      staticCliPackage = pkgs:
        let
          s = pkgs.pkgsStatic;
        in
        s.stdenv.mkDerivation {
          pname = "cerealgrain-cli";
          inherit version;
          src = cleanSource pkgs;
          nativeBuildInputs = [ pkgs.zig s.buildPackages.pkg-config pkgs.nukeReferences ];
          buildInputs = [ s.libtiff s.zlib s.libdeflate s.libjpeg ];
          allowedReferences = [ ];
          buildPhase = ''
            runHook preBuild
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
            mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
            zig build -Dstatic=true -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3 -Doptimize=ReleaseFast -Dversion=${version} \
              --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
              --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 zig-out/bin/cerealgrain "$out/bin/cerealgrain"
            nuke-refs "$out/bin/cerealgrain"
            install -Dm644 LICENSE "$out/share/licenses/cerealgrain/CerealGrain-LICENSE.txt"
            cp -R third_party/. "$out/share/licenses/cerealgrain/"
            runHook postInstall
          '';
          # The static stdenv records the libraries for static linking
          # against this package; an executable has no use for that.
          postFixup = ''
            rm -r "$out/nix-support"
          '';
          meta.mainProgram = "cerealgrain";
        };
    in
    {
      # The scanner's system side on NixOS: udev rules, SANE, and the
      # patched epkowa backend with the V600 wrappers (nixos/README.md).
      nixosModules.default = import ./nixos/v600-scanner.nix;
      overlays.default = import ./nixos/v600-overlay.nix;

      packages = forAllSystems (pkgs:
        let
          nuklear = nuklearPackage pkgs;
          mkPackage = { enableUi }:
            pkgs.stdenv.mkDerivation {
              pname = if enableUi then "cerealgrain-ui" else "cerealgrain-cli";
              inherit version;
              src = cleanSource pkgs;
              nativeBuildInputs = [ pkgs.zig pkgs.pkg-config pkgs.stdenv.cc ];
              buildInputs = [
                pkgs.libtiff
                pkgs.zlib
                pkgs.libdeflate
                pkgs.libjpeg
              ] ++ pkgs.lib.optionals enableUi [
                pkgs.sdl3
                nuklear
              ];
              buildPhase = ''
                runHook preBuild
                export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
                export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
                mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
                zig build ${pkgs.lib.optionalString enableUi "-Dui=true"} -Doptimize=ReleaseSafe -Dversion=${version} \
                  --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
                  --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p "$out"
                cp -R zig-out/* "$out"/
                runHook postInstall
              '';
              meta = {
                mainProgram = if enableUi then "cerealgrain-ui" else "cerealgrain";
              };
            };
          cli = mkPackage { enableUi = false; };
          ui = mkPackage { enableUi = true; };
        in {
          inherit cli ui;
          webgpuNative = pkgs.wgpu-native;
          default = ui;
        } // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          cli-static = staticCliPackage pkgs;
        });

      checks = forAllSystems (pkgs:
        let nuklear = nuklearPackage pkgs; in {
        zig-tests = pkgs.runCommand "cerealgrain-tests" {
          nativeBuildInputs = [ pkgs.zig pkgs.pkg-config pkgs.stdenv.cc pkgs.imagemagick pkgs.exiftool ];
          buildInputs = [ pkgs.libtiff pkgs.zlib pkgs.libdeflate pkgs.libjpeg pkgs.sdl3 nuklear ];
        } ''
          cp -R ${cleanSource pkgs} source
          chmod -R u+w source
          cd source
          export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
          mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
          zig build test \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
            --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
          zig build -Dui=true \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
            --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
          zig build scanner-smoke-skip scanner-processing-smoke-skip macos-scanner-smoke-skip \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
            --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
          zig build -Dui=true native-preview-worker-smoke-skip native-scan-worker-smoke-skip \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
            --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
          touch "$out"
        '';
      });

      devShells = forAllSystems (pkgs:
        let
          nuklear = nuklearPackage pkgs;
          webgpuRuntimeInputs = [ pkgs.wgpu-native ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.vulkan-loader ];
          pythonProcessing = pkgs.python3.withPackages (ps: with ps; [
            numpy
            opencv4
            tifffile
            scipy
            scikit-image
            numba
            pillow
            tomli
            tomli-w
          ]);
          baseNativeBuildInputs = with pkgs; [
            zig
            zls
            stdenv.cc
            pkg-config
            git # build.zig embeds the commit
            exiftool
            imagemagick
            pythonProcessing
            basedpyright
          ];
          baseBuildInputs = with pkgs; [
            sane-backends
            libusb1
            libtiff
            zlib
            libdeflate
            libjpeg
            sdl3
            nuklear
          ];
          shellHook = ''
            zig_version="$(zig version)"
            if [ "$zig_version" != "0.16.0" ]; then
              echo "warning: expected Zig 0.16.0, got $zig_version" >&2
            fi
          '';
        in {
        default = pkgs.mkShell {
          nativeBuildInputs = baseNativeBuildInputs;
          buildInputs = baseBuildInputs;
          inherit shellHook;
        };
        webgpu = pkgs.mkShell {
          nativeBuildInputs = baseNativeBuildInputs;
          buildInputs = baseBuildInputs ++ webgpuRuntimeInputs;
          WGPU_NATIVE_INCLUDE_DIR = "${pkgs.wgpu-native.dev}/include";
          WGPU_NATIVE_LIBRARY_DIR = "${pkgs.wgpu-native}/lib";
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath webgpuRuntimeInputs;
          shellHook = shellHook + ''
            echo "CerealGrain WebGPU shell: using nixpkgs wgpu-native (libwgpu_native, include/webgpu)" >&2
          '';
        };
      });
    };
}
