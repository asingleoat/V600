/*
 * LUT Dispatcher for Epson V600 Interpreter
 * 
 * This shared library intercepts calls to the interpreter and replaces
 * gamma LUT values at runtime based on environment variables or files.
 * 
 * Compile with:
 *   gcc -shared -fPIC -o libesintA1_lut.so lut_dispatcher.c -ldl
 * 
 * Use with:
 *   export V600_LUT_FILE=/tmp/custom_luts.bin
 *   export LD_PRELOAD=/path/to/libesintA1_lut.so
 *   scanimage ...
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

// Function pointers to real interpreter
static void* real_lib = NULL;
static uint8_t (*real_INTInit)(void*, void*, void*) = NULL;
static uint8_t (*real_INTWrite)(uint8_t*, uint32_t) = NULL;
static uint8_t (*real_INTRead)(uint8_t*, uint32_t) = NULL;
static void (*real_INTClose)(void) = NULL;

// Custom LUT storage
static uint8_t custom_luts[768];  // R[256] + G[256] + B[256]
static int luts_loaded = 0;
static int verbose = 0;

// Load custom LUTs from file
static void load_custom_luts() {
    const char* lut_file = getenv("V600_LUT_FILE");
    if (!lut_file) {
        if (verbose) fprintf(stderr, "[V600-LUT] No V600_LUT_FILE set, using identity LUTs\n");
        // Initialize with identity LUTs
        for (int i = 0; i < 256; i++) {
            custom_luts[i] = i;          // R
            custom_luts[256 + i] = i;    // G
            custom_luts[512 + i] = i;    // B
        }
        return;
    }
    
    FILE* f = fopen(lut_file, "rb");
    if (!f) {
        fprintf(stderr, "[V600-LUT] Failed to open LUT file: %s\n", lut_file);
        return;
    }
    
    size_t read = fread(custom_luts, 1, 768, f);
    fclose(f);
    
    if (read == 768) {
        luts_loaded = 1;
        fprintf(stderr, "[V600-LUT] Loaded custom LUTs from %s\n", lut_file);
        fprintf(stderr, "[V600-LUT]   R[0]=%02X R[128]=%02X R[255]=%02X\n", 
                custom_luts[0], custom_luts[128], custom_luts[255]);
        fprintf(stderr, "[V600-LUT]   G[0]=%02X G[128]=%02X G[255]=%02X\n", 
                custom_luts[256], custom_luts[384], custom_luts[511]);
        fprintf(stderr, "[V600-LUT]   B[0]=%02X B[128]=%02X B[255]=%02X\n", 
                custom_luts[512], custom_luts[640], custom_luts[767]);
    } else {
        fprintf(stderr, "[V600-LUT] Invalid LUT file size: expected 768, got %zu\n", read);
    }
}

// Load the real interpreter
static void load_real_interpreter() {
    if (real_lib) return;
    
    // Check for verbose mode
    verbose = getenv("V600_LUT_VERBOSE") != NULL;
    
    // Determine which interpreter to load based on mode
    const char* base_lib = getenv("V600_BASE_INTERPRETER");
    if (!base_lib) {
        // Fallback to searching for any interpreter
        base_lib = "libesintA1.so.2.0.1";
        if (verbose) fprintf(stderr, "[V600-LUT] No V600_BASE_INTERPRETER set, using fallback: %s\n", base_lib);
    }
    
    if (verbose) fprintf(stderr, "[V600-LUT] Loading base interpreter: %s\n", base_lib);
    
    real_lib = dlopen(base_lib, RTLD_NOW);
    if (!real_lib) {
        fprintf(stderr, "[V600-LUT] Failed to load interpreter: %s\n", dlerror());
        exit(1);
    }
    
    // Get function pointers
    real_INTInit = dlsym(real_lib, "INTInit");
    real_INTWrite = dlsym(real_lib, "INTWrite");
    real_INTRead = dlsym(real_lib, "INTRead");
    real_INTClose = dlsym(real_lib, "INTClose");
    
    // Load custom LUTs
    load_custom_luts();
}

// Intercept INTInit
uint8_t INTInit(void* a, void* b, void* c) {
    load_real_interpreter();
    if (verbose) fprintf(stderr, "[V600-LUT] INTInit called\n");
    return real_INTInit(a, b, c);
}

// Intercept INTWrite to replace gamma tables
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
                    fprintf(stderr, "[V600-LUT] Replaced %s gamma table\n", channel_name);
                } else if (verbose) {
                    // Show what's being sent
                    fprintf(stderr, "[V600-LUT] %s gamma table (identity): %02X %02X ... %02X %02X\n",
                            channel_name, buf[16], buf[17], buf[270], buf[271]);
                }
            }
        }
    }
    
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
    if (verbose) fprintf(stderr, "[V600-LUT] INTClose called\n");
    real_INTClose();
}

// Also hook INTPowerSavingMode if it exists
void INTPowerSavingMode(void) {
    if (!real_lib) load_real_interpreter();
    void (*real_func)(void) = dlsym(real_lib, "INTPowerSavingMode");
    if (real_func) real_func();
}