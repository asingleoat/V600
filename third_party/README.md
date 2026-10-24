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
| libtiff | 4.7.1 | libtiff | `libtiff` | macOS app, Linux CLI |
| libjpeg-turbo | 3.1.4 | IJG, BSD-3-Clause, Zlib | `libjpeg-turbo` | macOS app, Linux CLI |
| libwebp, libsharpyuv | 1.6.0 | BSD-3-Clause, with Google's patent grant | `libwebp` | macOS app, Linux CLI |
| LERC | 4.1.0 | Apache-2.0 | `lerc` | macOS app |
| liblzma (XZ Utils) | 5.8.3 | 0BSD | `xz` | macOS app, Linux CLI |
| zstd | 1.5.7 | BSD-3-Clause (dual-licensed with GPL-2.0; used under BSD) | `zstd` | macOS app, Linux CLI |
| libdeflate | 1.25 | MIT | `libdeflate` | macOS app, Linux CLI |
| zlib | 1.3.2 | Zlib | `zlib` | macOS app, Linux CLI |
| libusb | 1.0.29 | LGPL-2.1-or-later | `libusb` | macOS app |
| Zig standard library and runtime | 0.16.0 | MIT | `zig` | macOS app, Linux CLI |
| musl libc | 1.2.5 (as bundled with Zig) | MIT | `musl` | Linux CLI |

Notes:

- liblzma is 0BSD; `xz/COPYING` says which other parts of XZ Utils, none of
  them in liblzma, use other licenses.

## Source for the LGPL library

libusb ships in the macOS app as a separate dynamic library in
`Contents/Frameworks`, which can be replaced. Its source, as built:

- libusb 1.0.29: https://github.com/libusb/libusb/archive/v1.0.29.tar.gz

with the nixpkgs build recipes and patches at the `flake.lock` revision.
