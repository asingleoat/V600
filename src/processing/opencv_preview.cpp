#include <algorithm>
#include <cstddef>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

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

namespace {

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

double percentile_linear(std::vector<unsigned char>& values, double percent) {
    if (values.empty()) {
        return 0.0;
    }
    std::sort(values.begin(), values.end());
    const double rank = (static_cast<double>(values.size() - 1) * percent) / 100.0;
    const int lower = static_cast<int>(std::floor(rank));
    const int upper = static_cast<int>(std::ceil(rank));
    if (lower == upper) {
        return static_cast<double>(values[lower]);
    }
    const double weight = rank - static_cast<double>(lower);
    return static_cast<double>(values[lower]) * (1.0 - weight) +
        static_cast<double>(values[upper]) * weight;
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

    std::vector<cv::Mat> channels;
    cv::split(preview8, channels);
    for (int c = 0; c < 3; ++c) {
        std::vector<unsigned char> values;
        values.reserve(static_cast<size_t>(content_count));
        for (int y = 0; y < preview8.rows; ++y) {
            const unsigned char* mask_row = content_mask.data + static_cast<size_t>(y) * content_mask.step[0];
            const unsigned char* ch_row = channels[c].data + static_cast<size_t>(y) * channels[c].step[0];
            for (int x = 0; x < preview8.cols; ++x) {
                if (mask_row[x] != 0) {
                    values.push_back(ch_row[x]);
                }
            }
        }

        const double lo = percentile_linear(values, 1.0);
        const double hi = percentile_linear(values, 99.0);
        if (hi <= lo) {
            continue;
        }
        const float lo_f = static_cast<float>(lo);
        const float scale = 255.0f / static_cast<float>(hi - lo);
        for (int y = 0; y < preview8.rows; ++y) {
            unsigned char* ch_row = channels[c].data + static_cast<size_t>(y) * channels[c].step[0];
            for (int x = 0; x < preview8.cols; ++x) {
                float value = (static_cast<float>(ch_row[x]) - lo_f) * scale;
                if (value < 0.0f) {
                    value = 0.0f;
                } else if (value > 255.0f) {
                    value = 255.0f;
                }
                ch_row[x] = static_cast<unsigned char>(value);
            }
        }
    }
    cv::merge(channels, preview8);
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
    double* preview_scale
) {
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

    cv::Mat gray_raw;
    cv::cvtColor(preview8, gray_raw, cv::COLOR_RGB2GRAY);
    cv::Mat content_mask = gray_raw < 240;
    preview8 = cv::Scalar::all(255) - preview8;
    stretch_content_percentiles(preview8, content_mask);

    cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(2.0, cv::Size(8, 8));
    std::vector<cv::Mat> preview_channels;
    cv::split(preview8, preview_channels);
    for (int c = 0; c < 3; ++c) {
        cv::Mat enhanced;
        clahe->apply(preview_channels[c], enhanced);
        preview_channels[c] = enhanced;
    }
    cv::merge(preview_channels, preview8);
    return 0;
}

}  // namespace

extern "C" int v600_process_quick_preview(
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
        out_preview_scale);
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
        write_preview_raw(small_rgb, preview_raw);
    }
    if (preview_rgb8 != nullptr) {
        if (preview_rgb8_len < required_samples) {
            return -4;
        }
        for (int y = 0; y < preview8.rows; ++y) {
            const unsigned char* row = preview8.data + static_cast<size_t>(y) * preview8.step[0];
            std::memcpy(preview_rgb8 + static_cast<size_t>(y) * preview8.cols * 3, row, static_cast<size_t>(preview8.cols) * 3);
        }
    }

    cv::Mat bgr;
    cv::cvtColor(preview8, bgr, cv::COLOR_RGB2BGR);
    std::vector<unsigned char> encoded;
    std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 90};
    if (!cv::imencode(".jpg", bgr, encoded, params)) {
        return -5;
    }
    *jpeg_len = static_cast<int>(encoded.size());
    if (jpeg_buffer == nullptr || jpeg_capacity < *jpeg_len) {
        return 1;
    }
    std::memcpy(jpeg_buffer, encoded.data(), encoded.size());
    return 0;
}

extern "C" int v600_decode_jpeg_rgb(
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
