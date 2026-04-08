# NixOS overlay for Epson V600 scanner with 16-bit and IR scanning support
# This overlay patches the epkowa backend and creates wrapper scripts
#
# To use this overlay in your NixOS configuration:
#   nixpkgs.overlays = [ (import ./v600-overlay.nix) ];

(final: prev: {
  # Override epkowa with 16-bit support patches
  epkowa = prev.epkowa.overrideAttrs (oldAttrs: rec {
    # Add tools needed for patching
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
      final.python3
    ];
    
    # Apply patches to enable 16-bit scanning at high DPI
    postPatch = (oldAttrs.postPatch or "") + ''
      echo "Applying V600 16-bit scanning fix..."
      
      # Check if max_request_size already exists (newer iscan versions)
      if grep -q "max_request_size" backend/channel.h; then
        echo "max_request_size already exists, adapting patch..."
        
        # Look for existing channel_usb_max_request_size function
        if ! grep -q "channel_usb_max_request_size" backend/channel-usb.c; then
          echo "Adding channel_usb_max_request_size implementation..."
          
          # Add function declaration if needed
          sed -i '92a\static size_t channel_usb_max_request_size (const channel *);' backend/channel-usb.c
          
          # Set the function pointer
          sed -i 's/self->max_size = 128 \* 1024;/self->max_request_size = channel_usb_max_request_size;/' backend/channel-usb.c
          sed -i 's/self->max_size = 32 \* 1024;/self->max_request_size = channel_usb_max_request_size;/' backend/channel-usb.c
          
          # Add implementation that returns larger buffers for 16-bit scanning
          echo '
static size_t
channel_usb_max_request_size (const channel *self)
{
  /* Increased buffer sizes for 16-bit scanning */
  return (self->interpreter ? 256 : 1024) * 1024;
}' >> backend/channel-usb.c
        else
          echo "Function exists, modifying return values for larger buffers..."
          # Modify existing function to return larger values
          sed -i '/channel_usb_max_request_size/,/^}/s/return.*/return (self->interpreter ? 256 : 1024) * 1024;/' backend/channel-usb.c
        fi
        
        # Make sure epkowa.c calls the function if it doesn't already
        if grep -q "s->hw->channel->max_size" backend/epkowa.c; then
          sed -i 's/s->hw->channel->max_size/s->hw->channel->max_request_size(s->hw->channel)/g' backend/epkowa.c
        fi
      else
        echo "ERROR: Expected max_request_size but not found, check iscan version"
        exit 1
      fi
      
      # Critical fix: Enable 16-bit color processing in dip-obj.c
      echo "Fixing 16-bit color processing..."
      
      # Allow 16-bit depth (original code only allows 8-bit)
      sed -i 's/require (8 == buf->ctx\.depth);/require (buf->ctx.depth == 8 || buf->ctx.depth == 16);/' backend/dip-obj.c
      
      # Skip color profiling for 16-bit to avoid complexity
      sed -i '/if (SANE_FRAME_RGB != buf->ctx\.format)/a\
      \
        /* Skip color profiling for 16-bit depth */\
        if (buf->ctx.depth == 16) return;' backend/dip-obj.c
      
      echo "16-bit scanning fix applied"
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
      
      # Create IR patched version using Python script
      cat > patch_ir.py << 'EOF'
#!/usr/bin/env python3
import sys

def patch_binary(input_file, output_file):
    """Patch the interpreter binary to enable IR scanning mode."""
    with open(input_file, 'rb') as f:
        data = bytearray(f.read())
    
    # Bypass source=3 validation at 0x17c83
    # This allows the TPU+IR mode to be accepted
    offset1 = 0x17c83
    if len(data) > offset1 + 4 and data[offset1:offset1+4] == bytes([0x80, 0x7a, 0x1a, 0x03]):
        data[offset1+3] = 0x04  # Change comparison from 3 to 4
        print(f"Patched validation at {offset1:#x}")
    
    # Change TPU source from 1 to 3 at 0x18f01
    # This enables IR channel when TPU is selected
    offset2 = 0x18f01
    if len(data) > offset2 + 4 and data[offset2:offset2+4] == bytes([0xc6, 0x40, 0x1a, 0x01]):
        data[offset2+3] = 0x03  # Change source from 1 (TPU) to 3 (TPU+IR)
        print(f"Patched source at {offset2:#x}")
    
    with open(output_file, 'wb') as f:
        f.write(data)

if __name__ == "__main__":
    patch_binary(sys.argv[1], sys.argv[2])
EOF
      
      python3 patch_ir.py "$out/lib/libesintA1_normal.so" "$out/lib/libesintA1_ir.so"
      
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
    
    if [ -f "$NORMAL_LIB" ]; then
      # The interpreter needs C++ runtime libraries
      export LD_LIBRARY_PATH="${final.gcc-unwrapped.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      # Use LD_PRELOAD to force loading our normal interpreter
      export LD_PRELOAD="$NORMAL_LIB''${LD_PRELOAD:+:$LD_PRELOAD}"
    else
      echo "[V600] Warning: Normal interpreter not found at $NORMAL_LIB"
    fi
    
    exec ${prev.sane-backends}/bin/scanimage "$@"
  '';
  
  # Wrapper script for IR (infrared) scanning
  scanimage-v600-ir = final.writeShellScriptBin "scanimage-v600-ir" ''
    # IR scanning wrapper for Epson V600
    # Enables infrared channel for dust/scratch detection
    # Note: IR scanning requires:
    #   --source 'Transparency Unit'
    #   --mode Gray
    #   --resolution 800/1600/3200
    
    echo "[V600] IR mode - using infrared channel"
    
    # Use the patched IR interpreter
    IR_LIB="${final.v600-interpreters}/lib/libesintA1_ir.so"
    
    if [ -f "$IR_LIB" ]; then
      # The interpreter needs C++ runtime libraries
      export LD_LIBRARY_PATH="${final.gcc-unwrapped.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      # Use LD_PRELOAD to force loading our IR interpreter
      export LD_PRELOAD="$IR_LIB''${LD_PRELOAD:+:$LD_PRELOAD}"
    else
      echo "[V600] Warning: IR interpreter not found at $IR_LIB"
    fi
    
    exec ${prev.sane-backends}/bin/scanimage "$@"
  '';
})