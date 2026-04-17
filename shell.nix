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
  ];

  CPPFLAGS = "-DSANE_FRAME_IR";
}
