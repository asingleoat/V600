#include <setjmp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>

struct cerealgrain_jpeg_error {
    struct jpeg_error_mgr pub;
    jmp_buf setjmp_buffer;
};

static void cerealgrain_jpeg_error_exit(j_common_ptr cinfo) {
    struct cerealgrain_jpeg_error* err = (struct cerealgrain_jpeg_error*)cinfo->err;
    longjmp(err->setjmp_buffer, 1);
}

int cerealgrain_encode_rgb_jpeg(
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
    struct cerealgrain_jpeg_error jerr;
    unsigned char* encoded = NULL;
    unsigned long encoded_len = 0;

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = cerealgrain_jpeg_error_exit;
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

/* Writes an RGB JPEG to `path`, with its resolution in dots per inch in the
 * JFIF header. A failed write removes the partial file. */
int cerealgrain_write_rgb_jpeg_file(
    const char* path,
    const unsigned char* rgb,
    int width,
    int height,
    int quality,
    int dpi
) {
    if (path == NULL || rgb == NULL || width <= 0 || height <= 0 || quality <= 0 ||
        dpi <= 0 || dpi > 65535) {
        return -1;
    }

    struct jpeg_compress_struct cinfo;
    struct cerealgrain_jpeg_error jerr;
    FILE* volatile file = fopen(path, "wb");
    if (file == NULL) {
        return -4;
    }

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = cerealgrain_jpeg_error_exit;
    if (setjmp(jerr.setjmp_buffer)) {
        jpeg_destroy_compress(&cinfo);
        fclose(file);
        remove(path);
        return -2;
    }

    jpeg_create_compress(&cinfo);
    jpeg_stdio_dest(&cinfo, file);

    cinfo.image_width = (JDIMENSION)width;
    cinfo.image_height = (JDIMENSION)height;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;

    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    /* Full-resolution colour (4:4:4): prints show subsampled chroma. */
    cinfo.comp_info[0].h_samp_factor = 1;
    cinfo.comp_info[0].v_samp_factor = 1;
    cinfo.write_JFIF_header = TRUE;
    cinfo.density_unit = 1;
    cinfo.X_density = (UINT16)dpi;
    cinfo.Y_density = (UINT16)dpi;
    jpeg_start_compress(&cinfo, TRUE);

    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row_pointer[1];
        row_pointer[0] = (JSAMPROW)&rgb[(size_t)cinfo.next_scanline * (size_t)width * 3u];
        jpeg_write_scanlines(&cinfo, row_pointer, 1);
    }

    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    if (fclose(file) != 0) {
        remove(path);
        return -5;
    }
    return 0;
}
