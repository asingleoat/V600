#include <algorithm>
#include <cmath>
#include <csetjmp>

#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>

namespace {

thread_local std::jmp_buf* active_ecc_jump = nullptr;

// Do not let cv::Exception unwind into the Zig-linked executable.
int ecc_error_callback(
    int status,
    const char* func_name,
    const char* err_msg,
    const char* file_name,
    int line,
    void* userdata
) {
    (void)status;
    (void)func_name;
    (void)err_msg;
    (void)file_name;
    (void)line;
    (void)userdata;
    if (active_ecc_jump != nullptr) {
        std::longjmp(*active_ecc_jump, 1);
    }
    return 0;
}

unsigned char normalized_to_u8(double value, double max_value) {
    const double denom = max_value / 255.0 + 1e-10;
    double scaled = value / denom;
    if (!std::isfinite(scaled) || scaled < 0.0) {
        scaled = 0.0;
    }
    if (scaled > 255.0) {
        scaled = 255.0;
    }
    return static_cast<unsigned char>(scaled);
}

double max_value(const double* values, int count) {
    double result = 0.0;
    for (int i = 0; i < count; ++i) {
        result = std::max(result, values[i]);
    }
    return result;
}

}  // namespace

extern "C" int v600_align_ir_find_ecc_translation(
    const double* rgb,
    int rgb_width,
    int rgb_height,
    const double* ir,
    int ir_width,
    int ir_height,
    double* tx,
    double* ty
) {
    if (rgb == nullptr || ir == nullptr || tx == nullptr || ty == nullptr ||
        rgb_width <= 0 || rgb_height <= 0 || ir_width <= 0 || ir_height <= 0) {
        return -2;
    }

    const double rgb_max = max_value(rgb, rgb_width * rgb_height * 3);
    const double ir_max = max_value(ir, ir_width * ir_height);

    cv::Mat rgb8(rgb_height, rgb_width, CV_8UC3);
    for (int y = 0; y < rgb_height; ++y) {
        unsigned char* row = rgb8.data + static_cast<size_t>(y) * rgb8.step[0];
        for (int x = 0; x < rgb_width; ++x) {
            const int index = (y * rgb_width + x) * 3;
            row[x * 3] = normalized_to_u8(rgb[index], rgb_max);
            row[x * 3 + 1] = normalized_to_u8(rgb[index + 1], rgb_max);
            row[x * 3 + 2] = normalized_to_u8(rgb[index + 2], rgb_max);
        }
    }

    cv::Mat ir8(ir_height, ir_width, CV_8UC1);
    for (int y = 0; y < ir_height; ++y) {
        unsigned char* row = ir8.data + static_cast<size_t>(y) * ir8.step[0];
        for (int x = 0; x < ir_width; ++x) {
            row[x] = normalized_to_u8(ir[y * ir_width + x], ir_max);
        }
    }

    cv::Mat gray;
    cv::cvtColor(rgb8, gray, cv::COLOR_RGB2GRAY);

    const double res_ratio_y =
        static_cast<double>(rgb_height) / static_cast<double>(ir_height);
    const double res_ratio_x =
        static_cast<double>(rgb_width) / static_cast<double>(ir_width);
    if (std::abs(res_ratio_x - 1.0) > 0.01 ||
        std::abs(res_ratio_y - 1.0) > 0.01) {
        cv::resize(gray, gray, cv::Size(ir_width, ir_height), 0.0, 0.0, cv::INTER_AREA);
    }

    const double ecc_scale = 0.125;
    if (gray.cols < 16 || gray.rows < 16 || ir8.cols < 16 || ir8.rows < 16) {
        *tx = 0.0;
        *ty = 0.0;
        return -1;
    }

    cv::Mat small_gray;
    cv::Mat small_ir;
    cv::resize(gray, small_gray, cv::Size(), ecc_scale, ecc_scale, cv::INTER_AREA);
    cv::resize(ir8, small_ir, cv::Size(), ecc_scale, ecc_scale, cv::INTER_AREA);
    if (small_gray.cols < 2 || small_gray.rows < 2 ||
        small_ir.cols < 2 || small_ir.rows < 2) {
        *tx = 0.0;
        *ty = 0.0;
        return -1;
    }

    cv::Scalar gray_mean;
    cv::Scalar gray_stddev;
    cv::Scalar ir_mean;
    cv::Scalar ir_stddev;
    cv::meanStdDev(small_gray, gray_mean, gray_stddev);
    cv::meanStdDev(small_ir, ir_mean, ir_stddev);
    if (gray_stddev[0] <= 1e-6 || ir_stddev[0] <= 1e-6) {
        *tx = 0.0;
        *ty = 0.0;
        return -1;
    }

    cv::Mat warp_matrix = cv::Mat::eye(2, 3, CV_32F);
    const cv::TermCriteria criteria(
        cv::TermCriteria::EPS | cv::TermCriteria::COUNT,
        200,
        1e-6
    );

    void* previous_userdata = nullptr;
    cv::ErrorCallback previous_callback =
        cv::redirectError(ecc_error_callback, nullptr, &previous_userdata);
    std::jmp_buf jump_state;
    active_ecc_jump = &jump_state;
    if (setjmp(jump_state) != 0) {
        active_ecc_jump = nullptr;
        cv::redirectError(previous_callback, previous_userdata);
        *tx = 0.0;
        *ty = 0.0;
        return -1;
    }

    cv::findTransformECC(
        small_gray,
        small_ir,
        warp_matrix,
        cv::MOTION_TRANSLATION,
        criteria
    );
    active_ecc_jump = nullptr;
    cv::redirectError(previous_callback, previous_userdata);

    const unsigned char* warp_row0 = warp_matrix.data;
    const unsigned char* warp_row1 = warp_matrix.data + warp_matrix.step[0];
    *tx = static_cast<double>(reinterpret_cast<const float*>(warp_row0)[2]) / ecc_scale;
    *ty = static_cast<double>(reinterpret_cast<const float*>(warp_row1)[2]) / ecc_scale;
    return 0;
}
