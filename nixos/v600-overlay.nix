# NixOS overlay for Epson V600 scanner with 16-bit and IR scanning support
# This overlay patches the epkowa backend and creates wrapper scripts
#
# To use this overlay in your NixOS configuration:
#   nixpkgs.overlays = [ (import ./v600-overlay.nix) ];

(final: prev: {
  # Override epkowa with 16-bit support patches.
  #
  # Keep the patching logic in checked-in Python tools rather than inline sed:
  # the tools validate exact source/binary sites, are idempotent, and fail
  # loudly when Epson or nixpkgs changes the expected backend shape.
  epkowa = prev.epkowa.overrideAttrs (oldAttrs: rec {
    # Add tools needed for patching
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
      final.python3
    ];

    # Apply patches to enable 16-bit scanning at high DPI.
    postPatch = (oldAttrs.postPatch or "") + ''
      echo "Applying V600 epkowa source patch..."
      python3 ${./patch-epkowa-v600.py} .
    '';
  });
  
  # Create the patched interpreter package for IR support
  v600-interpreters = let
    # Get the interpreter source from Epson's firmware package
    interpreterSrc = final.fetchurl {
      urls = [
        "https://download2.ebz.epson.net/iscan/plugin/gt-x820/rpm/x64/iscan-gt-x820-bundle-2.30.4.x64.rpm.tar.gz"
        "https://web.archive.org/web/https://download2.ebz.epson.net/iscan/plugin/gt-x820/rpm/x64/iscan-gt-x820-bundle-2.30.4.x64.rpm.tar.gz"
      ];
      sha256 = "1vlba7dsgpk35nn3n7is8nwds3yzlk38q43mppjzwsz2d2n7sr33";
    };
  in final.stdenv.mkDerivation {
    name = "v600-interpreters";
    src = interpreterSrc;
    
    nativeBuildInputs = [ 
      final.rpm
      final.cpio
      final.python3
    ];
    
    unpackPhase = ''
      tar xf $src
      # The tarball extracts to iscan-gt-x820-bundle-2.30.4.x64.rpm/
      cd iscan-gt-x820-bundle-*.x64.rpm
      
      # The plugins directory should be here
      if [ -d plugins ]; then
        cd plugins
        ${final.rpm}/bin/rpm2cpio iscan-plugin-gt-x820-*.x86_64.rpm | ${final.cpio}/bin/cpio -idmv
      else
        # Try to find the RPM file
        RPM_FILE=$(find . -name "*.rpm" -type f | head -1)
        if [ -n "$RPM_FILE" ]; then
          ${final.rpm}/bin/rpm2cpio "$RPM_FILE" | ${final.cpio}/bin/cpio -idmv
        else
          echo "Error: Could not find RPM file"
          ls -laR
          exit 1
        fi
      fi
    '';
    
    buildPhase = ''
      mkdir -p $out/lib
      
      # Get the original interpreter from the extracted RPM
      ORIG_INTERP="usr/lib64/iscan/libesintA1.so.2.0.1"
      
      if [ ! -f "$ORIG_INTERP" ]; then
        echo "Error: Interpreter not found at expected path: $ORIG_INTERP"
        exit 1
      fi
      
      # Copy original as normal version
      cp "$ORIG_INTERP" "$out/lib/libesintA1_normal.so"
      
      python3 ${./patch-v600-interpreter-ir.py} \
        "$out/lib/libesintA1_normal.so" \
        "$out/lib/libesintA1_ir.so"
      
      echo "Created interpreters:"
      ls -la $out/lib/
    '';
    
    installPhase = ''
      # Already installed in buildPhase
      true
    '';
  };
  
  # Wrapper script for normal/color scanning with 16-bit support
  scanimage-v600 = final.writeShellScriptBin "scanimage-v600" ''
    # Normal/color scanning wrapper for Epson V600
    # Supports 16-bit depth at all resolutions (300-6400 DPI)

    # Use the standard unpatched interpreter
    NORMAL_LIB="${final.v600-interpreters}/lib/libesintA1_normal.so"
    SANE_BACKEND_DIR="${final.epkowa}/lib/sane"
    export SANE_CONFIG_DIR="''${SANE_CONFIG_DIR:-/etc/sane-config}"

    if [ ! -d "$SANE_BACKEND_DIR" ]; then
      echo "[V600] ERROR: epkowa SANE backend directory missing: $SANE_BACKEND_DIR" >&2
      exit 127
    fi
    if [ ! -f "$NORMAL_LIB" ]; then
      echo "[V600] ERROR: normal interpreter missing: $NORMAL_LIB" >&2
      exit 127
    fi

    # The interpreter needs C++ runtime libraries.
    export LD_LIBRARY_PATH="$SANE_BACKEND_DIR:${final.sane-backends}/lib/sane:${final.gcc-unwrapped.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # Use LD_PRELOAD to force loading our normal interpreter.
    export LD_PRELOAD="$NORMAL_LIB''${LD_PRELOAD:+:$LD_PRELOAD}"

    exec ${final.sane-backends}/bin/scanimage "$@"
  '';
  
  # Wrapper script for IR (infrared) scanning
  scanimage-v600-ir = final.writeShellScriptBin "scanimage-v600-ir" ''
    # IR scanning wrapper for Epson V600
    # Enables infrared channel for dust/scratch detection
    # Note: IR scanning requires:
    #   --source 'Transparency Unit'
    #   --mode Gray
    #   --resolution 800/1600/3200
    
    echo "[V600] IR mode - using infrared channel" >&2

    # Use the patched IR interpreter
    IR_LIB="${final.v600-interpreters}/lib/libesintA1_ir.so"
    SANE_BACKEND_DIR="${final.epkowa}/lib/sane"
    export SANE_CONFIG_DIR="''${SANE_CONFIG_DIR:-/etc/sane-config}"

    if [ ! -d "$SANE_BACKEND_DIR" ]; then
      echo "[V600] ERROR: epkowa SANE backend directory missing: $SANE_BACKEND_DIR" >&2
      exit 127
    fi
    if [ ! -f "$IR_LIB" ]; then
      echo "[V600] ERROR: IR interpreter missing: $IR_LIB" >&2
      exit 127
    fi

    # The interpreter needs C++ runtime libraries.
    export LD_LIBRARY_PATH="$SANE_BACKEND_DIR:${final.sane-backends}/lib/sane:${final.gcc-unwrapped.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # Use LD_PRELOAD to force loading our IR interpreter.
    export LD_PRELOAD="$IR_LIB''${LD_PRELOAD:+:$LD_PRELOAD}"

    exec ${final.sane-backends}/bin/scanimage "$@"
  '';
})
