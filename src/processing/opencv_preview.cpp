#include <algorithm>
#include <cstddef>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <time.h>
#include <vector>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

// The dynamic build links OpenCV's shared libraries but not libstdc++ itself,
// so the allocation operators and the one libstdc++ helper used come from
// here. The static build links libstdc++ and defines CEREALGRAIN_LIBSTDCXX.
#ifndef CEREALGRAIN_LIBSTDCXX
void* operator new(std::size_t size) {
    void* ptr = std::malloc(size == 0 ? 1 : size);
    if (ptr == nullptr) {
        std::abort();
    }
    return ptr;
}

void* operator new[](std::size_t size) {
    return operator new(size);
}

void operator delete(void* ptr) noexcept {
    std::free(ptr);
}

void operator delete[](void* ptr) noexcept {
    std::free(ptr);
}

void operator delete(void* ptr, std::size_t) noexcept {
    std::free(ptr);
}

void operator delete[](void* ptr, std::size_t) noexcept {
    std::free(ptr);
}

namespace std {
void __throw_length_error(const char*) {
    std::abort();
}
}  // namespace std
#endif

namespace {

struct QuickPreviewTiming {
    uint64_t geometry_ns = 0;
    uint64_t resize_ns = 0;
    uint64_t convert_ns = 0;
    uint64_t content_mask_ns = 0;
    uint64_t invert_stretch_ns = 0;
    uint64_t clahe_ns = 0;
    uint64_t raw_copy_ns = 0;
    uint64_t rgb_copy_ns = 0;
    uint64_t jpeg_encode_ns = 0;
    uint64_t jpeg_copy_ns = 0;
};

uint64_t monotonic_now_ns() {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + static_cast<uint64_t>(ts.tv_nsec);
}

uint64_t elapsed_ns(uint64_t start) {
    const uint64_t now = monotonic_now_ns();
    return now >= start ? now - start : 0;
}

int mat_type(int bits_per_sample, int channels) {
    if (bits_per_sample == 8 && channels == 1) {
        return CV_8UC1;
    }
    if (bits_per_sample == 8 && channels == 3) {
        return CV_8UC3;
    }
    if (bits_per_sample == 16 && channels == 1) {
        return CV_16UC1;
    }
    if (bits_per_sample == 16 && channels == 3) {
        return CV_16UC3;
    }
    return -1;
}

int histogram_select(const uint32_t hist[256], int target) {
    int seen = 0;
    for (int value = 0; value < 256; ++value) {
        seen += static_cast<int>(hist[value]);
        if (target < seen) {
            return value;
        }
    }
    return 255;
}

double percentile_linear_from_hist(const uint32_t hist[256], int count, double percent) {
    if (count <= 0) {
        return 0.0;
    }
    const double rank = (static_cast<double>(count - 1) * percent) / 100.0;
    const int lower = static_cast<int>(std::floor(rank));
    const int upper = static_cast<int>(std::ceil(rank));
    const int lower_value = histogram_select(hist, lower);
    if (lower == upper) {
        return static_cast<double>(lower_value);
    }
    const int upper_value = histogram_select(hist, upper);
    const double weight = rank - static_cast<double>(lower);
    return static_cast<double>(lower_value) * (1.0 - weight) +
        static_cast<double>(upper_value) * weight;
}

void convert_u16_to_u8_shift(const cv::Mat& input, cv::Mat& output) {
    output.create(input.rows, input.cols, input.channels() == 1 ? CV_8UC1 : CV_8UC3);
    const int channels = input.channels();
    for (int y = 0; y < input.rows; ++y) {
        const uint16_t* in_row = reinterpret_cast<const uint16_t*>(
            input.data + static_cast<size_t>(y) * input.step[0]);
        unsigned char* out_row = output.data + static_cast<size_t>(y) * output.step[0];
        for (int x = 0; x < input.cols * channels; ++x) {
            out_row[x] = static_cast<unsigned char>(in_row[x] >> 8);
        }
    }
}

void write_preview_raw(const cv::Mat& small_rgb, uint16_t* output) {
    cv::Mat raw_rgb;
    if (small_rgb.channels() == 1) {
        cv::cvtColor(small_rgb, raw_rgb, cv::COLOR_GRAY2RGB);
    } else {
        raw_rgb = small_rgb;
    }

    const int samples = raw_rgb.cols * raw_rgb.channels();
    if (raw_rgb.depth() == CV_16U) {
        for (int y = 0; y < raw_rgb.rows; ++y) {
            const uint16_t* row = reinterpret_cast<const uint16_t*>(
                raw_rgb.data + static_cast<size_t>(y) * raw_rgb.step[0]);
            std::memcpy(output + static_cast<size_t>(y) * samples, row, sizeof(uint16_t) * samples);
        }
    } else {
        for (int y = 0; y < raw_rgb.rows; ++y) {
            const unsigned char* row = raw_rgb.data + static_cast<size_t>(y) * raw_rgb.step[0];
            uint16_t* out_row = output + static_cast<size_t>(y) * samples;
            for (int x = 0; x < samples; ++x) {
                out_row[x] = static_cast<uint16_t>(row[x]) * 257u;
            }
        }
    }
}

void stretch_content_percentiles(cv::Mat& preview8, const cv::Mat& content_mask) {
    const int content_count = cv::countNonZero(content_mask);
    if (content_count <= 100) {
        return;
    }

    const int channels = preview8.channels();
    if (channels != 3) {
        return;
    }

    uint32_t hist[3][256] = {};
    for (int y = 0; y < preview8.rows; ++y) {
        const unsigned char* mask_row = content_mask.data + static_cast<size_t>(y) * content_mask.step[0];
        const unsigned char* rgb_row = preview8.data + static_cast<size_t>(y) * preview8.step[0];
        for (int x = 0; x < preview8.cols; ++x) {
            if (mask_row[x] == 0) {
                continue;
            }
            const unsigned char* sample = rgb_row + x * channels;
            hist[0][sample[0]] += 1;
            hist[1][sample[1]] += 1;
            hist[2][sample[2]] += 1;
        }
    }

    float lo_values[3] = {};
    float scales[3] = {};
    bool active[3] = {};
    for (int c = 0; c < 3; ++c) {
        const double lo = percentile_linear_from_hist(hist[c], content_count, 1.0);
        const double hi = percentile_linear_from_hist(hist[c], content_count, 99.0);
        if (hi <= lo) {
            continue;
        }
        lo_values[c] = static_cast<float>(lo);
        scales[c] = 255.0f / static_cast<float>(hi - lo);
        active[c] = true;
    }

    for (int y = 0; y < preview8.rows; ++y) {
        unsigned char* rgb_row = preview8.data + static_cast<size_t>(y) * preview8.step[0];
        for (int x = 0; x < preview8.cols; ++x) {
            unsigned char* sample = rgb_row + x * channels;
            for (int c = 0; c < 3; ++c) {
                if (!active[c]) {
                    continue;
                }
                float value = (static_cast<float>(sample[c]) - lo_values[c]) * scales[c];
                if (value < 0.0f) {
                    value = 0.0f;
                } else if (value > 255.0f) {
                    value = 255.0f;
                }
                sample[c] = static_cast<unsigned char>(value);
            }
        }
    }
}

int build_preview(
    const unsigned char* input,
    int width,
    int height,
    int channels,
    int bits_per_sample,
    int preview_size,
    cv::Mat& small_rgb,
    cv::Mat& preview8,
    double* preview_scale,
    QuickPreviewTiming* timing
) {
    uint64_t stage_start = monotonic_now_ns();
    const int type = mat_type(bits_per_sample, channels);
    if (input == nullptr || width <= 0 || height <= 0 || type < 0 || preview_scale == nullptr) {
        return -1;
    }

    cv::Mat rgb(height, width, type, const_cast<unsigned char*>(input));
    if (preview_size > 0) {
        *preview_scale = std::min(
            static_cast<double>(preview_size) / static_cast<double>(std::max(width, height)),
            1.0);
    } else {
        *preview_scale = 1.0;
    }
    if (timing != nullptr) {
        timing->geometry_ns += elapsed_ns(stage_start);
    }

    stage_start = monotonic_now_ns();
    if (*preview_scale < 1.0) {
        const int preview_width = static_cast<int>(static_cast<double>(width) * *preview_scale);
        const int preview_height = static_cast<int>(static_cast<double>(height) * *preview_scale);
        if (preview_width <= 0 || preview_height <= 0) {
            return -2;
        }
        cv::resize(rgb, small_rgb, cv::Size(preview_width, preview_height), 0.0, 0.0, cv::INTER_AREA);
    } else {
        small_rgb = rgb;
    }
    if (timing != nullptr) {
        timing->resize_ns += elapsed_ns(stage_start);
    }

    stage_start = monotonic_now_ns();
    if (small_rgb.depth() == CV_16U) {
        convert_u16_to_u8_shift(small_rgb, preview8);
    } else {
        preview8 = small_rgb.clone();
    }
    if (preview8.channels() == 1) {
        cv::Mat rgb8;
        cv::cvtColor(preview8, rgb8, cv::COLOR_GRAY2RGB);
        preview8 = rgb8;
    }
    if (timing != nullptr) {
        timing->convert_ns += elapsed_ns(stage_start);
    }

    stage_start = monotonic_now_ns();
    cv::Mat gray_raw;
    cv::cvtColor(preview8, gray_raw, cv::COLOR_RGB2GRAY);
    cv::Mat content_mask = gray_raw < 240;
    if (timing != nullptr) {
        timing->content_mask_ns += elapsed_ns(stage_start);
    }

    stage_start = monotonic_now_ns();
    preview8 = cv::Scalar::all(255) - preview8;
    stretch_content_percentiles(preview8, content_mask);
    if (timing != nullptr) {
        timing->invert_stretch_ns += elapsed_ns(stage_start);
    }

    stage_start = monotonic_now_ns();
    cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(2.0, cv::Size(8, 8));
    std::vector<cv::Mat> preview_channels;
    cv::split(preview8, preview_channels);
    for (int c = 0; c < 3; ++c) {
        cv::Mat enhanced;
        clahe->apply(preview_channels[c], enhanced);
        preview_channels[c] = enhanced;
    }
    cv::merge(preview_channels, preview8);
    if (timing != nullptr) {
        timing->clahe_ns += elapsed_ns(stage_start);
    }
    return 0;
}

int process_quick_preview_impl(
    const unsigned char* input,
    int width,
    int height,
    int channels,
    int bits_per_sample,
    int preview_size,
    int* out_width,
    int* out_height,
    double* out_preview_scale,
    uint16_t* preview_raw,
    int preview_raw_len,
    unsigned char* preview_rgb8,
    int preview_rgb8_len,
    unsigned char* jpeg_buffer,
    int jpeg_capacity,
    int* jpeg_len,
    QuickPreviewTiming* timing
) {
    if (out_width == nullptr || out_height == nullptr ||
        out_preview_scale == nullptr || jpeg_len == nullptr) {
        return -1;
    }

    cv::Mat small_rgb;
    cv::Mat preview8;
    const int build_status = build_preview(
        input,
        width,
        height,
        channels,
        bits_per_sample,
        preview_size,
        small_rgb,
        preview8,
        out_preview_scale,
        timing);
    if (build_status != 0) {
        return build_status;
    }

    *out_width = preview8.cols;
    *out_height = preview8.rows;
    const int required_samples = preview8.cols * preview8.rows * 3;
    if (preview_raw != nullptr) {
        if (preview_raw_len < required_samples) {
            return -3;
        }
        uint64_t stage_start = monotonic_now_ns();
        write_preview_raw(small_rgb, preview_raw);
        if (timing != nullptr) {
            timing->raw_copy_ns += elapsed_ns(stage_start);
        }
    }
    if (preview_rgb8 != nullptr) {
        if (preview_rgb8_len < required_samples) {
            return -4;
        }
        uint64_t stage_start = monotonic_now_ns();
        for (int y = 0; y < preview8.rows; ++y) {
            const unsigned char* row = preview8.data + static_cast<size_t>(y) * preview8.step[0];
            std::memcpy(preview_rgb8 + static_cast<size_t>(y) * preview8.cols * 3, row, static_cast<size_t>(preview8.cols) * 3);
        }
        if (timing != nullptr) {
            timing->rgb_copy_ns += elapsed_ns(stage_start);
        }
    }

    uint64_t stage_start = monotonic_now_ns();
    cv::Mat bgr;
    cv::cvtColor(preview8, bgr, cv::COLOR_RGB2BGR);
    std::vector<unsigned char> encoded;
    std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 90};
    if (!cv::imencode(".jpg", bgr, encoded, params)) {
        return -5;
    }
    if (timing != nullptr) {
        timing->jpeg_encode_ns += elapsed_ns(stage_start);
    }
    *jpeg_len = static_cast<int>(encoded.size());
    if (jpeg_buffer == nullptr || jpeg_capacity < *jpeg_len) {
        return 1;
    }
    stage_start = monotonic_now_ns();
    std::memcpy(jpeg_buffer, encoded.data(), encoded.size());
    if (timing != nullptr) {
        timing->jpeg_copy_ns += elapsed_ns(stage_start);
    }
    return 0;
}

}  // namespace

extern "C" int cerealgrain_process_quick_preview(
    const unsigned char* input,
    int width,
    int height,
    int channels,
    int bits_per_sample,
    int preview_size,
    int* out_width,
    int* out_height,
    double* out_preview_scale,
    uint16_t* preview_raw,
    int preview_raw_len,
    unsigned char* preview_rgb8,
    int preview_rgb8_len,
    unsigned char* jpeg_buffer,
    int jpeg_capacity,
    int* jpeg_len
) {
    return process_quick_preview_impl(
        input,
        width,
        height,
        channels,
        bits_per_sample,
        preview_size,
        out_width,
        out_height,
        out_preview_scale,
        preview_raw,
        preview_raw_len,
        preview_rgb8,
        preview_rgb8_len,
        jpeg_buffer,
        jpeg_capacity,
        jpeg_len,
        nullptr);
}

extern "C" int cerealgrain_process_quick_preview_breakdown(
    const unsigned char* input,
    int width,
    int height,
    int channels,
    int bits_per_sample,
    int preview_size,
    int* out_width,
    int* out_height,
    double* out_preview_scale,
    uint16_t* preview_raw,
    int preview_raw_len,
    unsigned char* preview_rgb8,
    int preview_rgb8_len,
    unsigned char* jpeg_buffer,
    int jpeg_capacity,
    int* jpeg_len,
    uint64_t* geometry_ns,
    uint64_t* resize_ns,
    uint64_t* convert_ns,
    uint64_t* content_mask_ns,
    uint64_t* invert_stretch_ns,
    uint64_t* clahe_ns,
    uint64_t* raw_copy_ns,
    uint64_t* rgb_copy_ns,
    uint64_t* jpeg_encode_ns,
    uint64_t* jpeg_copy_ns
) {
    QuickPreviewTiming timing;
    const int status = process_quick_preview_impl(
        input,
        width,
        height,
        channels,
        bits_per_sample,
        preview_size,
        out_width,
        out_height,
        out_preview_scale,
        preview_raw,
        preview_raw_len,
        preview_rgb8,
        preview_rgb8_len,
        jpeg_buffer,
        jpeg_capacity,
        jpeg_len,
        &timing);
    if (geometry_ns != nullptr) *geometry_ns = timing.geometry_ns;
    if (resize_ns != nullptr) *resize_ns = timing.resize_ns;
    if (convert_ns != nullptr) *convert_ns = timing.convert_ns;
    if (content_mask_ns != nullptr) *content_mask_ns = timing.content_mask_ns;
    if (invert_stretch_ns != nullptr) *invert_stretch_ns = timing.invert_stretch_ns;
    if (clahe_ns != nullptr) *clahe_ns = timing.clahe_ns;
    if (raw_copy_ns != nullptr) *raw_copy_ns = timing.raw_copy_ns;
    if (rgb_copy_ns != nullptr) *rgb_copy_ns = timing.rgb_copy_ns;
    if (jpeg_encode_ns != nullptr) *jpeg_encode_ns = timing.jpeg_encode_ns;
    if (jpeg_copy_ns != nullptr) *jpeg_copy_ns = timing.jpeg_copy_ns;
    return status;
}

extern "C" int cerealgrain_decode_jpeg_rgb(
    const unsigned char* jpeg,
    int jpeg_len,
    unsigned char* rgb_out,
    int rgb_capacity,
    int* out_width,
    int* out_height
) {
    if (jpeg == nullptr || jpeg_len <= 0 || out_width == nullptr || out_height == nullptr) {
        return -1;
    }
    std::vector<unsigned char> bytes(jpeg, jpeg + jpeg_len);
    cv::Mat bgr = cv::imdecode(bytes, cv::IMREAD_COLOR);
    if (bgr.empty()) {
        return -2;
    }
    *out_width = bgr.cols;
    *out_height = bgr.rows;
    const int required = bgr.cols * bgr.rows * 3;
    if (rgb_out == nullptr || rgb_capacity < required) {
        return 1;
    }
    cv::Mat rgb;
    cv::cvtColor(bgr, rgb, cv::COLOR_BGR2RGB);
    for (int y = 0; y < rgb.rows; ++y) {
        const unsigned char* row = rgb.data + static_cast<size_t>(y) * rgb.step[0];
        std::memcpy(rgb_out + static_cast<size_t>(y) * rgb.cols * 3, row, static_cast<size_t>(rgb.cols) * 3);
    }
    return 0;
}
