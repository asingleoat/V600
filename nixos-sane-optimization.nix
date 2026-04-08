# NixOS SANE Optimization for Epson V600
# Add this to your configuration.nix or as a separate module

{ config, pkgs, lib, ... }:

{
  # SANE configuration optimized for Epson V600
  hardware.sane = {
    enable = true;
    
    # Only enable the backends we actually need for V600
    # This dramatically speeds up scanner detection
    disabledDefaultBackends = [
      # Disable all backends except what we need
      "abaton"
      "agfafocus"
      "apple"
      "artec"
      "artec_eplus48u"
      "as6e"
      "avision"
      "bh"
      "canon"
      "canon630u"
      "canon_dr"
      "canon_lide70"
      "canon_pp"
      "cardscan"
      "coolscan"
      "coolscan2"
      "coolscan3"
      "dc210"
      "dc240"
      "dc25"
      "dell1600n_net"
      "dmc"
      "epjitsu"
      # "epson"      # Keep if using epson backend
      # "epson2"     # Keep if using epson2 backend  
      "epsonds"
      "escl"
      "fujitsu"
      "genesys"
      "gt68xx"
      "hp"
      "hp3500"
      "hp3900"
      "hp4200"
      "hp5400"
      "hp5590"
      "hpljm1005"
      "hpsj5s"
      "hs2p"
      "ibm"
      "kodak"
      "kodakaio"
      "kvs1025"
      "kvs20xx"
      "leo"
      "lexmark"
      "ma1509"
      "magicolor"
      "matsushita"
      "microtek"
      "microtek2"
      "mustek"
      "mustek_pp"
      "mustek_usb"
      "mustek_usb2"
      "nec"
      "net"
      "niash"
      "p5"
      "pie"
      "pieusb"
      "pixma"
      "plustek"
      "plustek_pp"
      "pnm"
      "qcam"
      "ricoh"
      "ricoh2"
      "rts8891"
      "s9036"
      "sceptre"
      "sharp"
      "sm3600"
      "sm3840"
      "snapscan"
      "sp15c"
      "st400"
      "stv680"
      "tamarack"
      "teco1"
      "teco2"
      "teco3"
      "test"
      "u12"
      "umax"
      "umax1220u"
      "umax_pp"
      "v4l"
      "xerox_mfp"
    ];

    # If using epkowa backend from iscan package
    extraBackends = [ pkgs.iscan ];
    
    # Configure the epkowa backend specifically
    configDir = "/etc/sane.d";
    
    # Extra configuration
    extraConfig = {
      # Disable network auto-discovery for epson2 (causes delays)
      "epson2" = ''
        # Disable network scanning - we only use USB
        # net autodiscovery
        # Comment out the above line to prevent network scanning delays
        
        # Specific USB device for V600
        usb 0x04b8 0x013a
      '';
      
      # Configure epkowa if using it
      "epkowa" = ''
        # USB device for V600
        usb 0x04b8 0x013a
        
        # Interpreter for V600 (adjust path as needed)
        interpreter usb 0x04b8 0x013a /nix/store/*/lib/iscan/libesintA1.so
      '';
      
      # Configure dll to only load what we need
      "dll" = ''
        # Only load the backend(s) we actually use
        # Comment out everything except:
        epkowa
        # epson2  # Uncomment if using epson2 instead of epkowa
      '';
    };
  };

  # Set environment variable for faster detection
  environment.variables = {
    # If you know your device name, set it here to skip detection
    # SANE_DEFAULT_DEVICE = "epkowa:interpreter:001:007";
    
    # Reduce debug output for faster operation
    SANE_DEBUG_DLL = "0";
  };

  # If using the 16bitV600 solution with wrapper scripts
  environment.systemPackages = with pkgs; [
    # Your custom scanner packages
    (writeScriptBin "scanimage-v600" ''
      #!${pkgs.bash}/bin/bash
      # Always use explicit device to avoid detection delay
      DEVICE="epkowa:interpreter:001:007"  # Update with your actual device
      exec ${pkgs.sane-backends}/bin/scanimage -d "$DEVICE" "$@"
    '')
    
    (writeScriptBin "scanimage-v600-ir" ''
      #!${pkgs.bash}/bin/bash
      # IR scanning wrapper with explicit device
      DEVICE="epkowa:interpreter:001:007"  # Update with your actual device
      export SCAN_IR_MODE=1
      exec ${pkgs.sane-backends}/bin/scanimage -d "$DEVICE" "$@"
    '')
  ];
}

# Alternative: Minimal configuration if you only need epkowa
# This is the most aggressive optimization

{ config, pkgs, lib, ... }:

{
  hardware.sane = {
    enable = true;
    
    # Disable ALL default backends
    disabledDefaultBackends = lib.mapAttrsToList (name: _: name) 
      config.hardware.sane.backends;
    
    # Only add epkowa
    extraBackends = [ pkgs.iscan ];
  };
  
  # Create custom dll.conf that ONLY loads epkowa
  environment.etc."sane.d/dll.conf" = {
    text = ''
      # Only load epkowa backend for V600
      epkowa
    '';
    # Override the default dll.conf
    mode = "0444";
  };
  
  # Create epkowa.conf
  environment.etc."sane.d/epkowa.conf" = {
    text = ''
      # Epson V600 configuration
      usb 0x04b8 0x013a
      interpreter usb 0x04b8 0x013a /nix/store/*/lib/iscan/libesintA1.so
    '';
    mode = "0444";
  };
}