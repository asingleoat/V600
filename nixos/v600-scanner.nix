# NixOS module for Epson Perfection V600 Photo scanner support
# This module enables full 16-bit color depth and infrared scanning capabilities
#
# To use this module, add it to your NixOS configuration:
#   imports = [ ./v600-scanner.nix ];

{ config, pkgs, lib, ... }:

{
  # Enable SANE scanner support
  hardware.sane = {
    enable = true;
    extraBackends = [ 
      pkgs.sane-airscan   # For network scanners (optional)
      pkgs.epkowa         # Epson proprietary backend (required for V600)
    ];
  };
  
  # Enable IPP-USB for driverless scanning (optional, but recommended)
  services.ipp-usb.enable = true;
  
  # Add epkowa backend to SANE configuration
  # This ensures the epkowa backend is loaded by SANE
  environment.etc."sane.d/dll.d/epkowa.conf".text = "epkowa";
  
  # udev rule for Epson Perfection V600 Photo scanner
  # This grants proper permissions for USB access
  services.udev.extraRules = ''
    # Epson Perfection V600 Photo scanner
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="013a", MODE="0666", GROUP="scanner", TAG+="uaccess"
  '';
  
  # Add scanner utilities to system packages
  environment.systemPackages = with pkgs; [
    # GUI scanner applications
    simple-scan    # GNOME simple scanner interface
    xsane         # Advanced scanner interface
    
    # Command-line scanner tools (with V600 wrappers if overlay is used)
    # These will be available if you use the v600-overlay.nix
    (lib.mkIf (builtins.hasAttr "scanimage-v600" pkgs) pkgs.scanimage-v600)
    (lib.mkIf (builtins.hasAttr "scanimage-v600-ir" pkgs) pkgs.scanimage-v600-ir)
  ];
  
  # Ensure users who need scanner access are in the scanner group
  # Add your username to this group in your main configuration:
  # users.users.yourname.extraGroups = [ "scanner" "lp" ];
}