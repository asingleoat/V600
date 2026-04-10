/*
 * Unified Dispatcher for Epson V600 Interpreter
 * 
 * This single dispatcher replaces the need for multiple patched interpreters.
 * It handles:
 *   - Normal scanning
 *   - IR scanning (runtime source=3 patching)
 *   - Custom LUTs (runtime gamma table replacement)
 * 
 * Compile with:
 *   gcc -shared -fPIC -o libesintA1_unified.so unified_dispatcher.c -ldl
 * 
 * Use with:
 *   export SCAN_IR_MODE=1           # Enable IR mode
 *   export V600_LUT_FILE=/tmp/luts.bin  # Custom LUTs
 *   export LD_PRELOAD=/path/to/libesintA1_unified.so
 *   scanimage ...
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/stat.h>

// Function pointers to real interpreter
static void* real_lib = NULL;
static uint8_t (*real_INTInit)(void*, void*, void*) = NULL;
static uint8_t (*real_INTWrite)(uint8_t*, uint32_t) = NULL;
static uint8_t (*real_INTRead)(uint8_t*, uint32_t) = NULL;
static void (*real_INTClose)(void) = NULL;

// Mode configuration
static int ir_mode = 0;
static int verbose = 0;

// Custom LUT storage
static uint8_t custom_luts[768];  // R[256] + G[256] + B[256]
static int luts_loaded = 0;

// Original interpreter binary (before any patches)
static uint8_t* original_binary = NULL;
static size_t binary_size = 0;

// Load custom LUTs from file
static void load_custom_luts() {
    const char* lut_file = getenv("V600_LUT_FILE");
    if (!lut_file) {
        if (verbose) fprintf(stderr, "[V600] No V600_LUT_FILE set, using identity LUTs\n");
        // Initialize with identity LUTs
        for (int i = 0; i < 256; i++) {
            custom_luts[i] = i;          // R
            custom_luts[256 + i] = i;    // G
            custom_luts[512 + i] = i;    // B
        }
        luts_loaded = 0;
        return;
    }
    
    FILE* f = fopen(lut_file, "rb");
    if (!f) {
        fprintf(stderr, "[V600] Failed to open LUT file: %s\n", lut_file);
        return;
    }
    
    size_t read = fread(custom_luts, 1, 768, f);
    fclose(f);
    
    if (read == 768) {
        luts_loaded = 1;
        fprintf(stderr, "[V600] Loaded custom LUTs from %s\n", lut_file);
        if (verbose) {
            fprintf(stderr, "[V600]   R[0]=%02X R[128]=%02X R[255]=%02X\n", 
                    custom_luts[0], custom_luts[128], custom_luts[255]);
            fprintf(stderr, "[V600]   G[0]=%02X G[128]=%02X G[255]=%02X\n", 
                    custom_luts[256], custom_luts[384], custom_luts[511]);
            fprintf(stderr, "[V600]   B[0]=%02X B[128]=%02X B[255]=%02X\n", 
                    custom_luts[512], custom_luts[640], custom_luts[767]);
        }
    } else {
        fprintf(stderr, "[V600] Invalid LUT file size: expected 768, got %zu\n", read);
    }
}

// Create IR-patched interpreter in memory
static void* create_ir_interpreter(const char* base_path) {
    // Read the original interpreter
    FILE* f = fopen(base_path, "rb");
    if (!f) {
        fprintf(stderr, "[V600] Failed to open base interpreter: %s\n", base_path);
        return NULL;
    }
    
    fseek(f, 0, SEEK_END);
    binary_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    original_binary = malloc(binary_size);
    if (!original_binary) {
        fclose(f);
        return NULL;
    }
    
    if (fread(original_binary, 1, binary_size, f) != binary_size) {
        fclose(f);
        free(original_binary);
        return NULL;
    }
    fclose(f);
    
    // Apply IR patches (from our working IR interpreter)
    // Patch 1: Bypass source=3 validation at 0x17c83
    if (binary_size > 0x17c83 + 4) {
        if (memcmp(original_binary + 0x17c83, "\x80\x7a\x1a\x03", 4) == 0) {
            original_binary[0x17c83 + 3] = 0x04;  // Change comparison from 3 to 4
            if (verbose) fprintf(stderr, "[V600] Applied IR patch 1: validation bypass\n");
        }
    }
    
    // Patch 2: Change TPU source from 1 to 3 at 0x18f01
    if (binary_size > 0x18f01 + 4) {
        if (memcmp(original_binary + 0x18f01, "\xc6\x40\x1a\x01", 4) == 0) {
            original_binary[0x18f01 + 3] = 0x03;  // Change source from 1 to 3
            if (verbose) fprintf(stderr, "[V600] Applied IR patch 2: source 1→3\n");
        }
    }
    
    // Create a temp file and write the patched binary
    char temp_path[] = "/tmp/libesintA1_ir_XXXXXX.so";
    int fd = mkstemps(temp_path, 3);
    if (fd < 0) {
        free(original_binary);
        return NULL;
    }
    
    if (write(fd, original_binary, binary_size) != binary_size) {
        close(fd);
        unlink(temp_path);
        free(original_binary);
        return NULL;
    }
    
    close(fd);
    chmod(temp_path, 0755);
    
    // Load the patched interpreter
    void* lib = dlopen(temp_path, RTLD_NOW);
    
    // Clean up temp file (library stays in memory)
    unlink(temp_path);
    free(original_binary);
    original_binary = NULL;
    
    return lib;
}

// Load the appropriate interpreter based on mode
static void load_real_interpreter() {
    if (real_lib) return;
    
    // Check configuration from environment
    verbose = getenv("V600_VERBOSE") != NULL;
    ir_mode = getenv("SCAN_IR_MODE") != NULL;
    
    // Get base interpreter path
    const char* base_lib = getenv("V600_BASE_INTERPRETER");
    if (!base_lib) {
        // Fallback to searching for any interpreter
        base_lib = "libesintA1.so.2.0.1";
        if (verbose) fprintf(stderr, "[V600] No V600_BASE_INTERPRETER set, using fallback: %s\n", base_lib);
    }
    
    if (ir_mode) {
        fprintf(stderr, "[V600] IR mode enabled - patching interpreter\n");
        real_lib = create_ir_interpreter(base_lib);
    } else {
        if (verbose) fprintf(stderr, "[V600] Normal mode - loading base interpreter: %s\n", base_lib);
        real_lib = dlopen(base_lib, RTLD_NOW);
    }
    
    if (!real_lib) {
        fprintf(stderr, "[V600] Failed to load interpreter: %s\n", dlerror());
        exit(1);
    }
    
    // Get function pointers
    real_INTInit = dlsym(real_lib, "INTInit");
    real_INTWrite = dlsym(real_lib, "INTWrite");
    real_INTRead = dlsym(real_lib, "INTRead");
    real_INTClose = dlsym(real_lib, "INTClose");
    
    if (!real_INTInit || !real_INTWrite || !real_INTRead || !real_INTClose) {
        fprintf(stderr, "[V600] Failed to find required symbols in interpreter\n");
        exit(1);
    }
    
    // Load custom LUTs if specified
    load_custom_luts();
}

// Intercept INTInit
uint8_t INTInit(void* a, void* b, void* c) {
    load_real_interpreter();
    if (verbose) fprintf(stderr, "[V600] INTInit called\n");
    return real_INTInit(a, b, c);
}

// Intercept INTWrite to replace gamma tables and handle other modifications
uint8_t INTWrite(uint8_t* buf, uint32_t len) {
    if (!real_lib) load_real_interpreter();
    
    // Check for RS 0x84 command (gamma table upload)
    // Format: 1E 00 84 00 06 00 00 00 [8-byte header] [256-byte LUT]
    if (len >= 272 && buf[0] == 0x1E && buf[2] == 0x84) {
        // This is a register write command
        // Check the header to see which gamma table
        if (len >= 272 && buf[8] == 0x03 && buf[9] == 0x00) {
            uint8_t table_id = buf[10];  // 0xFC=R, 0xFD=G, 0xFE=B
            
            if (table_id == 0xFC || table_id == 0xFD || table_id == 0xFE) {
                // This is a gamma table upload
                int channel = (table_id == 0xFC) ? 0 : (table_id == 0xFD) ? 1 : 2;
                const char* channel_name = (channel == 0) ? "R" : (channel == 1) ? "G" : "B";
                
                if (luts_loaded) {
                    // Replace the LUT data (starts at offset 16)
                    memcpy(buf + 16, custom_luts + (channel * 256), 256);
                    fprintf(stderr, "[V600] Replaced %s gamma table with custom LUT\n", channel_name);
                } else if (verbose) {
                    // Show what's being sent
                    fprintf(stderr, "[V600] %s gamma table (identity): %02X %02X ... %02X %02X\n",
                            channel_name, buf[16], buf[17], buf[270], buf[271]);
                }
            }
        }
    }
    
    // Additional command interception could go here
    // For example, we could modify scan parameters, resolution, etc.
    
    return real_INTWrite(buf, len);
}

// Pass through INTRead
uint8_t INTRead(uint8_t* buf, uint32_t len) {
    if (!real_lib) load_real_interpreter();
    return real_INTRead(buf, len);
}

// Pass through INTClose
void INTClose(void) {
    if (!real_lib) load_real_interpreter();
    if (verbose) fprintf(stderr, "[V600] INTClose called\n");
    real_INTClose();
}

// Also hook INTPowerSavingMode if it exists
void INTPowerSavingMode(void) {
    if (!real_lib) load_real_interpreter();
    void (*real_func)(void) = dlsym(real_lib, "INTPowerSavingMode");
    if (real_func) real_func();
}