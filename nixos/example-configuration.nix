# Example NixOS configuration for V600 scanner support.
# Adapt to your system and merge into your configuration.nix.

{ config, pkgs, ... }:

{
  imports = [
    ./v600-scanner.nix
  ];

  nixpkgs.overlays = [
    (import ./v600-overlay.nix)
  ];

  nixpkgs.config.allowUnfree = true;

  users.users.yourname = {
    isNormalUser = true;
    extraGroups = [ "scanner" "lp" ];
  };
}
