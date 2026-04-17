{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
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

    # Dev tools
    basedpyright
  ] ++ lib.optionals stdenv.isLinux [
    # Qt platform plugins (xcb for X11, wayland)
    qt6.qtbase
    qt6.qtwayland
  ];

  CPPFLAGS = "-DSANE_FRAME_IR";

  # Qt needs to find its platform plugins at runtime
  QT_PLUGIN_PATH = pkgs.lib.optionalString pkgs.stdenv.isLinux
    "${pkgs.qt6.qtbase.outPath}/${pkgs.qt6.qtbase.qtPluginPrefix}";
}
