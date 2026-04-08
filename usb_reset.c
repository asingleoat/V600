/*
 * USB reset utility for Epson V600 scanner
 * Sends reset commands directly via USB to recover from bad states
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

#define EPSON_VENDOR_ID 0x04b8
#define V600_PRODUCT_ID 0x013a

// ESC/I-2 commands
#define ESC 0x1B
#define FS  0x1C

// Reset sequence commands
static unsigned char cmd_reset[] = {ESC, '@'};  // ESC @ - Reset
static unsigned char cmd_get_identity[] = {FS, 'I'};  // FS I - Get identity
static unsigned char cmd_get_status[] = {FS, 'S'};  // FS S - Get status

int find_scanner_device() {
    char path[256];
    int fd;
    
    // Try common USB device paths
    for (int bus = 1; bus <= 10; bus++) {
        for (int dev = 1; dev <= 127; dev++) {
            sprintf(path, "/dev/bus/usb/%03d/%03d", bus, dev);
            
            fd = open(path, O_RDWR);
            if (fd < 0) continue;
            
            struct usbdevfs_connectinfo ci;
            if (ioctl(fd, USBDEVFS_CONNECTINFO, &ci) >= 0) {
                // Check vendor and product ID
                struct usb_device_descriptor {
                    uint8_t  bLength;
                    uint8_t  bDescriptorType;
                    uint16_t bcdUSB;
                    uint8_t  bDeviceClass;
                    uint8_t  bDeviceSubClass;
                    uint8_t  bDeviceProtocol;
                    uint8_t  bMaxPacketSize0;
                    uint16_t idVendor;
                    uint16_t idProduct;
                    uint16_t bcdDevice;
                    uint8_t  iManufacturer;
                    uint8_t  iProduct;
                    uint8_t  iSerialNumber;
                    uint8_t  bNumConfigurations;
                } __attribute__((packed)) desc;
                
                // Read descriptor
                lseek(fd, 0, SEEK_SET);
                if (read(fd, &desc, sizeof(desc)) == sizeof(desc)) {
                    if (desc.idVendor == EPSON_VENDOR_ID && desc.idProduct == V600_PRODUCT_ID) {
                        printf("Found V600 scanner at %s\n", path);
                        return fd;
                    }
                }
            }
            close(fd);
        }
    }
    
    return -1;
}

int send_bulk_command(int fd, unsigned char endpoint, unsigned char *cmd, int len) {
    struct usbdevfs_bulktransfer bulk;
    bulk.ep = endpoint;
    bulk.len = len;
    bulk.timeout = 500; // 500ms - shorter timeout
    bulk.data = cmd;
    
    int ret = ioctl(fd, USBDEVFS_BULK, &bulk);
    // Timeout is expected for commands with no response
    if (ret < 0 && errno != ETIMEDOUT) {
        perror("USBDEVFS_BULK");
        return -1;
    }
    
    return 0; // Success even on timeout
}

int reset_scanner(int fd) {
    printf("Sending reset command (ESC @)...\n");
    
    // Try endpoint 0x02 (common OUT endpoint)
    if (send_bulk_command(fd, 0x02, cmd_reset, sizeof(cmd_reset)) < 0) {
        // Try endpoint 0x01
        if (send_bulk_command(fd, 0x01, cmd_reset, sizeof(cmd_reset)) < 0) {
            printf("Failed to send reset command\n");
            return -1;
        }
    }
    
    printf("Reset command sent\n");
    usleep(500000); // Wait 500ms
    
    return 0;
}

int usb_device_reset(int fd) {
    printf("Performing USB device reset...\n");
    
    if (ioctl(fd, USBDEVFS_RESET, 0) < 0) {
        perror("USBDEVFS_RESET");
        return -1;
    }
    
    printf("USB device reset completed\n");
    return 0;
}

int main() {
    printf("Epson V600 USB Reset Tool\n");
    printf("=========================\n\n");
    
    int fd = find_scanner_device();
    if (fd < 0) {
        printf("Error: Could not find V600 scanner\n");
        printf("Make sure the scanner is connected and powered on\n");
        return 1;
    }
    
    // Try to claim the interface
    int interface = 0;
    if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &interface) < 0) {
        printf("Warning: Could not claim interface (may be in use by driver)\n");
        printf("Trying to reset anyway...\n");
    }
    
    // Try scanner reset command first
    if (reset_scanner(fd) == 0) {
        printf("Scanner reset successful\n");
    } else {
        printf("Scanner command failed, trying USB reset...\n");
        
        // Fall back to USB device reset
        if (usb_device_reset(fd) == 0) {
            printf("USB reset successful\n");
        } else {
            printf("USB reset failed\n");
        }
    }
    
    // Release interface
    ioctl(fd, USBDEVFS_RELEASEINTERFACE, &interface);
    
    close(fd);
    
    // Wait a moment for scanner to reinitialize
    printf("\nWaiting for scanner to reinitialize...\n");
    sleep(2);
    
    // Check if scanner is available
    system("scanimage -L 2>/dev/null | grep epkowa");
    
    return 0;
}