{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    (python3.withPackages (ps: with ps; [
      opencv4
      tifffile
      numpy
      pillow
      scikit-image
      pyusb
      scipy
    ]))
    exiftool
    imagemagick

    # sane-backends build deps
    autoconf
    autoconf-archive
    automake
    libtool
    pkg-config
    libusb1
    libjpeg
    libtiff
    libpng
  ];

  CPPFLAGS = "-DSANE_FRAME_IR";
}
