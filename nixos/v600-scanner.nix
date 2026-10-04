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
  
  # Add epkowa backend to SANE configuration. NixOS' SANE build reads
  # /etc/sane-config; keep /etc/sane.d as a compatibility breadcrumb for
  # non-NixOS tooling and older notes.
  environment.etc."sane-config/dll.d/epkowa.conf".text = "epkowa";
  environment.etc."sane.d/dll.d/epkowa.conf".text = "epkowa";
  
  # udev rules for the Epson film scanners CerealGrain knows (the model table
  # in src/scanner/models.zig); only the V600 has been tested.
  # This grants proper permissions for USB access
  services.udev.extraRules = ''
    # Perfection V600 / GT-X820 (tested)
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="013a", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection V550
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="013b", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection V800 / V850
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0151", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection V700 / V750 / GT-X900
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="012c", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # GT-X970
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0135", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection V500 / GT-X770
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0130", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection 4990 / GT-X800
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="012a", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection 4870 / GT-X700
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0128", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection 4490 / GT-X750
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0119", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection V370 / V37
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="014a", MODE="0666", GROUP="scanner", TAG+="uaccess"
    # Perfection V330 / V33
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0142", MODE="0666", GROUP="scanner", TAG+="uaccess"
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
