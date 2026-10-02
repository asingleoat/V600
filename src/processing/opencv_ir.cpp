#include <cmath>
#include <cstdlib>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

extern "C" int v600_estimate_local_grain(
    const double* roi_rgb,
    const unsigned char* roi_mask,
    int width,
    int height,
    int grain_padding,
    double grain_sigma,
    double* grain_std,
    double* signal_out,
    double* spectrum_out,
    int spectrum_capacity,
    int* spectrum_len,
    int* has_spectrum
) {
    if (roi_rgb == nullptr || roi_mask == nullptr || grain_std == nullptr ||
        signal_out == nullptr || spectrum_out == nullptr ||
        spectrum_len == nullptr || has_spectrum == nullptr ||
        width <= 0 || height <= 0 || grain_padding < 0 || !(grain_sigma > 0.0)) {
        return -1;
    }

    *spectrum_len = 0;
    *has_spectrum = 0;
    grain_std[0] = 0.0;
    grain_std[1] = 0.0;
    grain_std[2] = 0.0;

    cv::Mat rgb(height, width, CV_32FC3);
    for (int y = 0; y < height; ++y) {
        float* row = reinterpret_cast<float*>(rgb.data + static_cast<size_t>(y) * rgb.step[0]);
        for (int x = 0; x < width; ++x) {
            const int index = (y * width + x) * 3;
            row[x * 3] = static_cast<float>(roi_rgb[index]);
            row[x * 3 + 1] = static_cast<float>(roi_rgb[index + 1]);
            row[x * 3 + 2] = static_cast<float>(roi_rgb[index + 2]);
        }
    }

    cv::Mat mask_u8(height, width, CV_8UC1);
    for (int y = 0; y < height; ++y) {
        unsigned char* row = mask_u8.data + static_cast<size_t>(y) * mask_u8.step[0];
        for (int x = 0; x < width; ++x) {
            row[x] = roi_mask[y * width + x] != 0 ? 255 : 0;
        }
    }

    cv::Mat kernel = cv::getStructuringElement(
        cv::MORPH_ELLIPSE,
        cv::Size(2 * grain_padding + 1, 2 * grain_padding + 1)
    );
    cv::Mat dilated;
    cv::dilate(mask_u8, dilated, kernel);

    // Normalized convolution: the low-pass of the clean pixels only, so the
    // defect does not leak into the values around it.
    cv::Mat signal;
    {
        cv::Mat known(height, width, CV_32FC3);
        for (int y = 0; y < height; ++y) {
            float* row = reinterpret_cast<float*>(known.data + static_cast<size_t>(y) * known.step[0]);
            for (int x = 0; x < width; ++x) {
                const float value = roi_mask[y * width + x] != 0 ? 0.0f : 1.0f;
                row[x * 3] = value;
                row[x * 3 + 1] = value;
                row[x * 3 + 2] = value;
            }
        }
        cv::Mat weighted = rgb.mul(known);
        cv::Mat numerator;
        cv::Mat denominator;
        cv::GaussianBlur(weighted, numerator, cv::Size(0, 0), grain_sigma);
        cv::GaussianBlur(known, denominator, cv::Size(0, 0), grain_sigma);
        signal = rgb.clone();
        for (int y = 0; y < height; ++y) {
            const float* num_row = reinterpret_cast<const float*>(numerator.data + static_cast<size_t>(y) * numerator.step[0]);
            const float* den_row = reinterpret_cast<const float*>(denominator.data + static_cast<size_t>(y) * denominator.step[0]);
            float* out_row = reinterpret_cast<float*>(signal.data + static_cast<size_t>(y) * signal.step[0]);
            for (int i = 0; i < width * 3; ++i) {
                if (den_row[i] > 1.0e-3f) out_row[i] = num_row[i] / den_row[i];
            }
        }
    }

    int surround_count = 0;
    int clean_count = 0;
    for (int y = 0; y < height; ++y) {
        const unsigned char* mask_row = mask_u8.data + static_cast<size_t>(y) * mask_u8.step[0];
        const unsigned char* dilated_row = dilated.data + static_cast<size_t>(y) * dilated.step[0];
        for (int x = 0; x < width; ++x) {
            const bool masked = mask_row[x] != 0;
            if (!masked) {
                clean_count += 1;
            }
            if (dilated_row[x] != 0 && !masked) {
                surround_count += 1;
            }
        }
    }

    double sum[3] = {0.0, 0.0, 0.0};
    double sum_sq[3] = {0.0, 0.0, 0.0};
    if (surround_count > 10) {
        for (int y = 0; y < height; ++y) {
            const unsigned char* mask_row = mask_u8.data + static_cast<size_t>(y) * mask_u8.step[0];
            const unsigned char* dilated_row = dilated.data + static_cast<size_t>(y) * dilated.step[0];
            const float* rgb_row = reinterpret_cast<const float*>(rgb.data + static_cast<size_t>(y) * rgb.step[0]);
            const float* signal_row = reinterpret_cast<const float*>(signal.data + static_cast<size_t>(y) * signal.step[0]);
            for (int x = 0; x < width; ++x) {
                if (dilated_row[x] == 0 || mask_row[x] != 0) {
                    continue;
                }
                for (int c = 0; c < 3; ++c) {
                    const float grain = rgb_row[x * 3 + c] - signal_row[x * 3 + c];
                    sum[c] += static_cast<double>(grain);
                    sum_sq[c] += static_cast<double>(grain) * static_cast<double>(grain);
                }
            }
        }
        for (int c = 0; c < 3; ++c) {
            const double mean = sum[c] / static_cast<double>(surround_count);
            double variance = sum_sq[c] / static_cast<double>(surround_count) - mean * mean;
            if (variance < 0.0) {
                variance = 0.0;
            }
            grain_std[c] = static_cast<double>(static_cast<float>(std::sqrt(variance)));
        }
    }

    for (int y = 0; y < height; ++y) {
        const float* signal_row = reinterpret_cast<const float*>(signal.data + static_cast<size_t>(y) * signal.step[0]);
        for (int x = 0; x < width; ++x) {
            const int index = (y * width + x) * 3;
            signal_out[index] = static_cast<double>(signal_row[x * 3]);
            signal_out[index + 1] = static_cast<double>(signal_row[x * 3 + 1]);
            signal_out[index + 2] = static_cast<double>(signal_row[x * 3 + 2]);
        }
    }

    const int r_max = (height < width ? height : width) / 2;
    if (surround_count <= 64 || r_max <= 0 || spectrum_capacity < r_max) {
        return 0;
    }

    double* spectrum_sum = spectrum_out;
    int* ring_count = static_cast<int*>(std::malloc(sizeof(int) * static_cast<size_t>(r_max)));
    if (ring_count == nullptr) {
        return -1;
    }
    for (int r = 0; r < r_max; ++r) {
        spectrum_sum[r] = 0.0;
        ring_count[r] = 0;
    }

    cv::Mat dft_input(height, width, CV_64FC1);
    cv::Mat dft_output;
    const int cy = height / 2;
    const int cx = width / 2;
    const double pi = 3.141592653589793238462643383279502884;
    const int y_shift = (height + 1) / 2;
    const int x_shift = (width + 1) / 2;
    // Rings of equal frequency, in bins of the shorter side: a DFT bin is
    // 1/width cycles per pixel across and 1/height down.
    const double short_side = static_cast<double>(height < width ? height : width);
    const double x_bin = short_side / static_cast<double>(width);
    const double y_bin = short_side / static_cast<double>(height);

    for (int c = 0; c < 3; ++c) {
        for (int y = 0; y < height; ++y) {
            const unsigned char* mask_row = mask_u8.data + static_cast<size_t>(y) * mask_u8.step[0];
            const float* rgb_row = reinterpret_cast<const float*>(rgb.data + static_cast<size_t>(y) * rgb.step[0]);
            const float* signal_row = reinterpret_cast<const float*>(signal.data + static_cast<size_t>(y) * signal.step[0]);
            double* input_row = reinterpret_cast<double*>(dft_input.data + static_cast<size_t>(y) * dft_input.step[0]);
            const double wy = height > 1
                ? 0.5 - 0.5 * std::cos(2.0 * pi * static_cast<double>(y) / static_cast<double>(height - 1))
                : 1.0;
            for (int x = 0; x < width; ++x) {
                const double wx = width > 1
                    ? 0.5 - 0.5 * std::cos(2.0 * pi * static_cast<double>(x) / static_cast<double>(width - 1))
                    : 1.0;
                double grain = static_cast<double>(rgb_row[x * 3 + c] - signal_row[x * 3 + c]);
                if (mask_row[x] != 0) {
                    grain = 0.0;
                }
                input_row[x] = grain * wy * wx;
            }
        }

        cv::dft(dft_input, dft_output, cv::DFT_COMPLEX_OUTPUT);
        for (int y = 0; y < height; ++y) {
            const int src_y = (y + y_shift) % height;
            const double dy = static_cast<double>(y - cy) * y_bin;
            const double* dft_row = reinterpret_cast<const double*>(dft_output.data + static_cast<size_t>(src_y) * dft_output.step[0]);
            for (int x = 0; x < width; ++x) {
                const int src_x = (x + x_shift) % width;
                const double dx = static_cast<double>(x - cx) * x_bin;
                const int ri = static_cast<int>(std::sqrt(dx * dx + dy * dy));
                if (ri < 0 || ri >= r_max) {
                    continue;
                }
                const double re = dft_row[src_x * 2];
                const double im = dft_row[src_x * 2 + 1];
                spectrum_sum[ri] += (re * re + im * im) / 3.0;
                if (c == 0) {
                    ring_count[ri] += 1;
                }
            }
        }
    }

    double spectrum_total = 0.0;
    const double clean_fraction =
        static_cast<double>(clean_count) / static_cast<double>(width * height);
    for (int r = 0; r < r_max; ++r) {
        if (ring_count[r] > 0) {
            spectrum_sum[r] /= static_cast<double>(ring_count[r]);
        }
        if (clean_fraction > 0.1) {
            spectrum_sum[r] /= clean_fraction * clean_fraction;
        }
        spectrum_total += spectrum_sum[r];
    }

    if (spectrum_total > 0.0) {
        for (int r = 0; r < r_max; ++r) {
            spectrum_out[r] = spectrum_sum[r] / spectrum_total;
        }
        *spectrum_len = r_max;
        *has_spectrum = 1;
    }

    std::free(ring_count);
    return 0;
}

extern "C" int v600_synthesize_grain_from_noise(
    const double* noise,
    int width,
    int height,
    const double* grain_std,
    const double* grain_spectrum,
    int spectrum_len,
    int channels,
    double* output
) {
    if (noise == nullptr || grain_std == nullptr || output == nullptr ||
        width <= 0 || height <= 0 || channels <= 0 ||
        (spectrum_len > 0 && grain_spectrum == nullptr)) {
        return -1;
    }

    cv::Mat dft_input(height, width, CV_64FC1);
    cv::Mat dft_output;
    cv::Mat inverse_output;
    const int cy = height / 2;
    const int cx = width / 2;
    const int y_shift = height / 2;
    const int x_shift = width / 2;
    // Rings of equal frequency, in bins of the shorter side, as measured.
    const double short_side = static_cast<double>(height < width ? height : width);
    const double x_bin = short_side / static_cast<double>(width);
    const double y_bin = short_side / static_cast<double>(height);

    for (int c = 0; c < channels; ++c) {
        for (int y = 0; y < height; ++y) {
            double* input_row = reinterpret_cast<double*>(dft_input.data + static_cast<size_t>(y) * dft_input.step[0]);
            for (int x = 0; x < width; ++x) {
                input_row[x] = noise[(c * height + y) * width + x];
            }
        }

        cv::dft(dft_input, dft_output, cv::DFT_COMPLEX_OUTPUT);
        for (int y = 0; y < height; ++y) {
            double* dft_row = reinterpret_cast<double*>(dft_output.data + static_cast<size_t>(y) * dft_output.step[0]);
            for (int x = 0; x < width; ++x) {
                const int centered_y = (y + y_shift) % height;
                const int centered_x = (x + x_shift) % width;
                const double dy = static_cast<double>(centered_y - cy) * y_bin;
                const double dx = static_cast<double>(centered_x - cx) * x_bin;
                const double radius = std::sqrt(dx * dx + dy * dy);
                double amp = 1.0;
                if (grain_spectrum != nullptr && spectrum_len > 4) {
                    if (radius >= static_cast<double>(spectrum_len - 1)) {
                        amp = std::sqrt(grain_spectrum[spectrum_len - 1] > 0.0 ? grain_spectrum[spectrum_len - 1] : 0.0);
                    } else {
                        const int lower = static_cast<int>(std::floor(radius));
                        const int upper = lower + 1;
                        const double t = radius - static_cast<double>(lower);
                        const double low = std::sqrt(grain_spectrum[lower] > 0.0 ? grain_spectrum[lower] : 0.0);
                        const double high = std::sqrt(grain_spectrum[upper] > 0.0 ? grain_spectrum[upper] : 0.0);
                        amp = low * (1.0 - t) + high * t;
                    }
                } else {
                    const double safe_radius = radius > 0.0 ? radius : 1.0;
                    amp = 1.0 / safe_radius;
                }
                dft_row[x * 2] *= amp;
                dft_row[x * 2 + 1] *= amp;
            }
        }

        cv::dft(dft_output, inverse_output, cv::DFT_INVERSE | cv::DFT_SCALE | cv::DFT_REAL_OUTPUT);

        double sum = 0.0;
        double sum_sq = 0.0;
        const int count = width * height;
        for (int y = 0; y < height; ++y) {
            const double* row = reinterpret_cast<const double*>(inverse_output.data + static_cast<size_t>(y) * inverse_output.step[0]);
            for (int x = 0; x < width; ++x) {
                const double value = row[x];
                sum += value;
                sum_sq += value * value;
            }
        }
        const double mean = sum / static_cast<double>(count);
        double variance = sum_sq / static_cast<double>(count) - mean * mean;
        if (variance < 0.0) {
            variance = 0.0;
        }
        const double noise_std = std::sqrt(variance);

        for (int y = 0; y < height; ++y) {
            const double* row = reinterpret_cast<const double*>(inverse_output.data + static_cast<size_t>(y) * inverse_output.step[0]);
            for (int x = 0; x < width; ++x) {
                double shaped = row[x];
                if (noise_std > 0.0) {
                    shaped /= noise_std;
                }
                output[(y * width + x) * channels + c] =
                    static_cast<double>(static_cast<float>(shaped * grain_std[c]));
            }
        }
    }

    return 0;
}
