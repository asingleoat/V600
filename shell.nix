{ pkgs ? import <nixpkgs> {}, withWebGPU ? false }:

let
  zigPkg =
    if pkgs ? zig_0_16
    then pkgs.zig_0_16
    else if pkgs.lib.getVersion pkgs.zig == "0.16.0"
    then pkgs.zig
    else throw "CerealGrain shell.nix requires Zig 0.16.0. Update the nixpkgs channel, or enter the flake shell with `nix develop path:.` / direnv `use flake`.";

  zlsPkg =
    if pkgs ? zls_0_16
    then pkgs.zls_0_16
    else pkgs.zls;

  nuklear = pkgs.stdenvNoCC.mkDerivation {
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
in pkgs.mkShell {
  buildInputs = with pkgs; [
    (python3.withPackages (ps: with ps; [
      # Shared
      opencv4
      tifffile
      numpy
      pillow
      scikit-image

      # Scanner (V600)
      pyusb
      scipy
      ruff

      # Processing (scratchndent)
      numba
      tomli
      tomli-w
      radon

      # GUI
      pywebview
      typing-extensions
    ] ++ lib.optionals stdenv.isLinux [
      # pywebview Qt backend (Linux only; macOS uses native Cocoa)
      qtpy
      pyqt6
      pyqt6-webengine
      pyqt6-sip
    ]))

    # Shared tools
    exiftool
    imagemagick
    nodejs

    # Zig rewrite toolchain
    zigPkg
    zlsPkg
    git # build.zig embeds the commit

    # Scanner build deps
    gcc
    autoconf
    autoconf-archive
    automake
    libtool
    pkg-config
    libusb1
    libjpeg
    libtiff
    libpng
    zlib
    libdeflate
    opencv
    superlu

    # Dev tools
    basedpyright
  ] ++ lib.optionals (pkgs ? sdl3) [
    sdl3
  ] ++ [
    nuklear
  ] ++ lib.optionals withWebGPU [
    wgpu-native
  ] ++ lib.optionals (withWebGPU && stdenv.isLinux) [
    vulkan-loader
  ] ++ lib.optionals stdenv.isLinux [
    # Qt platform plugins (xcb for X11, wayland)
    qt6.qtbase
    qt6.qtwayland
  ];

  CPPFLAGS = "-DSANE_FRAME_IR";
  WGPU_NATIVE_INCLUDE_DIR = pkgs.lib.optionalString withWebGPU "${pkgs.wgpu-native.dev}/include";
  WGPU_NATIVE_LIBRARY_DIR = pkgs.lib.optionalString withWebGPU "${pkgs.wgpu-native}/lib";

  # Qt needs to find its platform plugins at runtime
  QT_PLUGIN_PATH = pkgs.lib.optionalString pkgs.stdenv.isLinux
    "${pkgs.qt6.qtbase.outPath}/${pkgs.qt6.qtbase.qtPluginPrefix}";

  shellHook = ''
    zig_version="$(zig version 2>/dev/null || true)"
    if [ "$zig_version" != "0.16.0" ]; then
      echo "warning: expected Zig 0.16.0, got ''${zig_version:-missing}" >&2
    fi
    if [ "${if withWebGPU then "1" else "0"}" = "1" ]; then
      export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath ([ pkgs.wgpu-native ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.vulkan-loader ])}''${LD_LIBRARY_PATH:+:}$LD_LIBRARY_PATH"
      echo "CerealGrain WebGPU shell: using nixpkgs wgpu-native (libwgpu_native, include/webgpu)" >&2
    fi
  '';
}
