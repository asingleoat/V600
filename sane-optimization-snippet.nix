# Add this to your configuration.nix to optimize SANE for V600
# This should reduce scanimage -L time from 13+ seconds to ~1-2 seconds

{
  # Optimized SANE configuration for Epson V600
  hardware.sane = {
    enable = true;
    
    # Add epkowa backend from iscan
    extraBackends = [ pkgs.iscan ];
  };

  # Override the dll.conf to only load epkowa
  # This is the KEY optimization - only load the one backend we need
  environment.etc."sane.d/dll.conf" = {
    text = ''
      # Only load epkowa backend - disables all others
      # This dramatically speeds up scanner detection
      epkowa
      
      # If you need other scanners, add them here:
      # epson2
      # brother4
    '';
    # Ensure this overrides the default
    mode = "0644";
  };
  
  # Configure epkowa backend
  environment.etc."sane.d/epkowa.conf" = {
    text = ''
      # Epson V600 USB configuration
      usb 0x04b8 0x013a
      
      # Path to interpreter will be resolved by Nix
      # If using 16bitV600 overlay, this is handled automatically
    '';
    mode = "0644";
  };
  
  # Optional: Set default device to skip detection entirely
  # Uncomment and update with your actual device name after first detection
  # environment.variables = {
  #   SANE_DEFAULT_DEVICE = "epkowa:interpreter:001:007";
  # };
  
  # Optional: Create wrapper scripts with hardcoded device
  environment.systemPackages = with pkgs; [
    (writeScriptBin "v600-scan" ''
      #!${pkgs.bash}/bin/bash
      # Fast scanner access with hardcoded device
      # Update the device string after running scanimage -L once
      
      # First time: detect and cache
      if [ ! -f ~/.v600-device ]; then
        echo "Detecting scanner (one-time setup)..."
        DEVICE=$(scanimage -L 2>/dev/null | grep -E "epkowa|V600|GT-X820" | sed "s/.*\`\(.*\)'.*/\1/")
        if [ -n "$DEVICE" ]; then
          echo "$DEVICE" > ~/.v600-device
          echo "Cached device: $DEVICE"
        else
          echo "Scanner not found!"
          exit 1
        fi
      fi
      
      DEVICE=$(cat ~/.v600-device)
      exec scanimage -d "$DEVICE" "$@"
    '')
  ];
}