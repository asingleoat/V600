# The dev shell is the flake's (flake.nix); this loads it for `nix-shell`
# and direnv's `use nix`. Needs flakes enabled. Pass
# `--arg withWebGPU true` for the WebGPU shell. The checkout is named as git
# so only tracked files reach the store, never scans/ or frames/.
{ withWebGPU ? false }:
let
  flake = builtins.getFlake "git+file://${toString ./.}";
  shells = flake.devShells.${builtins.currentSystem};
in
if withWebGPU then shells.webgpu else shells.default
