#include <setjmp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>

struct v600_jpeg_error {
    struct jpeg_error_mgr pub;
    jmp_buf setjmp_buffer;
};

static void v600_jpeg_error_exit(j_common_ptr cinfo) {
    struct v600_jpeg_error* err = (struct v600_jpeg_error*)cinfo->err;
    longjmp(err->setjmp_buffer, 1);
}

int v600_encode_rgb_jpeg(
    const unsigned char* rgb,
    int width,
    int height,
    int quality,
    unsigned char* jpeg_buffer,
    int jpeg_capacity,
    int* jpeg_len
) {
    if (rgb == NULL || width <= 0 || height <= 0 || quality <= 0 ||
        jpeg_len == NULL || jpeg_capacity < 0) {
        return -1;
    }

    struct jpeg_compress_struct cinfo;
    struct v600_jpeg_error jerr;
    unsigned char* encoded = NULL;
    unsigned long encoded_len = 0;

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = v600_jpeg_error_exit;
    if (setjmp(jerr.setjmp_buffer)) {
        jpeg_destroy_compress(&cinfo);
        free(encoded);
        return -2;
    }

    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, &encoded, &encoded_len);

    cinfo.image_width = (JDIMENSION)width;
    cinfo.image_height = (JDIMENSION)height;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;

    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    jpeg_start_compress(&cinfo, TRUE);

    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row_pointer[1];
        row_pointer[0] = (JSAMPROW)&rgb[(size_t)cinfo.next_scanline * (size_t)width * 3u];
        jpeg_write_scanlines(&cinfo, row_pointer, 1);
    }

    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);

    if (encoded_len > (unsigned long)2147483647) {
        free(encoded);
        return -3;
    }
    *jpeg_len = (int)encoded_len;
    if (jpeg_buffer == NULL || (unsigned long)jpeg_capacity < encoded_len) {
        free(encoded);
        return 1;
    }
    memcpy(jpeg_buffer, encoded, encoded_len);
    free(encoded);
    return 0;
}
