# Example NixOS configuration showing how to integrate V600 scanner support
# This is a complete example that you can adapt to your needs

{ config, pkgs, ... }:

{
  # Import other modules as needed
  imports = [
    # Your hardware configuration
    /etc/nixos/hardware-configuration.nix
    
    # V600 scanner support module
    ./v600-scanner.nix
  ];

  # Apply the V600 overlay for patched epkowa and wrapper scripts
  nixpkgs.overlays = [
    (import ./v600-overlay.nix)
  ];

  # Allow unfree packages (required for epkowa)
  nixpkgs.config.allowUnfree = true;

  # Your regular NixOS configuration...
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos-desktop";
  networking.networkmanager.enable = true;

  time.timeZone = "America/New_York";

  # Add scanner applications to system packages
  environment.systemPackages = with pkgs; [
    # Development tools (if you want to run the V600 GUI)
    python3
    python3Packages.numpy
    python3Packages.pillow
    python3Packages.tifffile
    python3Packages.pyusb
    python3Packages.flask
    python3Packages.scipy
    
    # Scanner utilities (from v600-scanner.nix, but listed here for clarity)
    simple-scan           # Simple GUI scanner
    xsane                # Advanced scanner interface
    scanimage-v600       # Command-line wrapper for color/grayscale
    scanimage-v600-ir    # Command-line wrapper for infrared
    
    # Other useful tools
    imagemagick          # For image conversion/manipulation
    gimp                 # For editing scanned images
  ];

  # Example user configuration with scanner access
  users.users.alice = {
    isNormalUser = true;
    description = "Alice";
    extraGroups = [ 
      "wheel"           # Admin access
      "networkmanager"  # Network configuration
      "scanner"         # Scanner access (REQUIRED for V600)
      "lp"             # Printer access (often needed for scanners)
    ];
    shell = pkgs.bash;
  };

  # Optional: If you want to use the V600 GUI web interface
  # Allow the Flask development server port
  networking.firewall.allowedTCPPorts = [ 5001 ];

  # System services
  services.openssh.enable = true;
  services.printing.enable = true;  # Often needed alongside scanning

  system.stateVersion = "23.11";
}

# After saving this configuration:
# 1. sudo nixos-rebuild switch
# 2. Log out and back in (to apply group membership)
# 3. Test with: scanimage -L
# 4. Scan with: scanimage-v600 --mode Color --depth 16 --resolution 300 -o test.tiff