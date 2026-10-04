# Third-party software

CerealGrain's own code is under the MIT license (`LICENSE` at the top of the
repository). The binaries it ships also contain the libraries below, each
under its own license; their license texts are here, one folder per
component. The macOS app (`zig build app-bundle`) carries this directory in
`CerealGrain.app/Contents/Resources/Licenses` and in its zip, and the static
Linux CLI (`nix build .#cli-static`) in `share/licenses/cerealgrain`.

Every component is built by nixpkgs at the revision pinned in `flake.lock`;
`nix build --inputs-from . nixpkgs#<package>.src` fetches the exact source.

| Component | Version | License | Folder | Ships in |
| --- | --- | --- | --- | --- |
| SDL | 3.4.2 | Zlib | `sdl3` | macOS app |
| Nuklear, with stb_truetype, stb_rect_pack, and the ProggyClean font | 4.12.7 | MIT or public domain; ProggyClean MIT | `nuklear` | macOS app |
| OpenCV (core, imgproc, imgcodecs) | 4.13.0 | Apache-2.0 | `opencv` | macOS app, Linux CLI |
| libtiff | 4.7.1 | libtiff | `libtiff` | macOS app, Linux CLI |
| libjpeg-turbo | 3.1.4 | IJG, BSD-3-Clause, Zlib | `libjpeg-turbo` | macOS app, Linux CLI |
| libpng (with APNG) | 1.6.56 | libpng-2.0 | `libpng` | macOS app |
| libwebp, libsharpyuv | 1.6.0 | BSD-3-Clause, with Google's patent grant | `libwebp` | macOS app, Linux CLI |
| LERC | 4.1.0 | Apache-2.0 | `lerc` | macOS app |
| OpenJPEG | 2.5.4 | BSD-2-Clause | `openjpeg` | macOS app |
| liblzma (XZ Utils) | 5.8.3 | 0BSD | `xz` | macOS app, Linux CLI |
| zstd | 1.5.7 | BSD-3-Clause (dual-licensed with GPL-2.0; used under BSD) | `zstd` | macOS app, Linux CLI |
| libdeflate | 1.25 | MIT | `libdeflate` | macOS app, Linux CLI |
| zlib | 1.3.2 | Zlib | `zlib` | macOS app, Linux CLI |
| SuperLU, with COLAMD | 7.0.1 | BSD-3-Clause-LBNL, Xerox notice, COLAMD terms | `superlu` | macOS app, Linux CLI |
| OpenBLAS, with LAPACK | 0.3.32 | BSD-3-Clause | `openblas` | macOS app, Linux CLI |
| libusb | 1.0.29 | LGPL-2.1-or-later | `libusb` | macOS app |
| libintl (GNU gettext) | 1.0 | LGPL-2.1-or-later | `libintl` | macOS app |
| libiconv, libcharset (Apple) | 109.100.2 | BSD-2-Clause, BSD-3-Clause; libcharset APSL-1.0 | `libiconv` | macOS app |
| GCC runtime: libgfortran, libgcc_s (macOS); libstdc++, libgcc (Linux) | 15.2.0 | GPL-3.0-or-later with the GCC Runtime Library Exception 3.1 | `gcc-runtime` | macOS app, Linux CLI |
| libquadmath (GCC) | 15.2.0 | LGPL-2.0-or-later (the LGPL-2.1 text is included) | `gcc-runtime` | macOS app |
| Zig standard library and runtime | 0.16.0 | MIT | `zig` | macOS app, Linux CLI |
| musl libc | 1.2.5 (as bundled with Zig) | MIT | `musl` | Linux CLI |

Notes:

- OpenCV has been Apache-2.0 since 4.5; nixpkgs' metadata still says
  BSD-3-Clause. `opencv/3rdparty` holds the licenses the macOS OpenCV build
  installs for code compiled into it. ittnotify is dual-licensed with
  GPL-2.0 and used under BSD-3-Clause. The Linux CLI's OpenCV is built
  without any of that third-party code.
- SuperLU: `License.txt` also reproduces the terms of MC64, which forbid
  passing it on. nixpkgs deletes MC64 from the source and links Debian's stub
  in its place, so no MC64 code ships. Most of SuperLU's routines carry the
  Xerox notice, and its COLAMD the terms in `COLAMD-NOTICE.txt`.
- liblzma is 0BSD; `xz/COPYING` says which other parts of XZ Utils, none of
  them in liblzma, use other licenses.
- The GCC Runtime Library Exception lets programs of any license link the
  GCC runtime libraries.

## Source for the LGPL libraries

libusb, libintl, and libquadmath ship in the macOS app as separate dynamic
libraries in `Contents/Frameworks`, which can be replaced. Their source, as
built:

- libusb 1.0.29: https://github.com/libusb/libusb/archive/v1.0.29.tar.gz
- GNU gettext 1.0 (libintl): https://ftp.gnu.org/gnu/gettext/gettext-1.0.tar.gz
- GCC 15.2.0 (libquadmath, libgfortran, libgcc_s, libstdc++, libgcc):
  https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz

with the nixpkgs build recipes and patches at the `flake.lock` revision.
