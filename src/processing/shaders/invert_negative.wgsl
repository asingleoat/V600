struct InvertNegativeParams {
    dmin: vec4<f32>,
    coeffs0: vec4<f32>,
    coeffs1: vec4<f32>,
    coeffs2: vec4<f32>,
    coeffs3: vec4<f32>,
    coeffs4: vec4<f32>,
    coeffs5: vec4<f32>,
    coeffs6: vec4<f32>,
    coeffs7: vec4<f32>,
    default_light: f32,
    pixel_count: u32,
    dispatch_width: u32,
    pad0: u32,
};

@group(0) @binding(0) var<storage, read> input_values: array<f32>;
@group(0) @binding(1) var<storage, read_write> output_values: array<f32>;
@group(0) @binding(2) var<uniform> params: InvertNegativeParams;

fn coeff(index: u32) -> f32 {
    let lane = index & 3u;
    switch (index >> 2u) {
        case 0u: { return params.coeffs0[lane]; }
        case 1u: { return params.coeffs1[lane]; }
        case 2u: { return params.coeffs2[lane]; }
        case 3u: { return params.coeffs3[lane]; }
        case 4u: { return params.coeffs4[lane]; }
        case 5u: { return params.coeffs5[lane]; }
        case 6u: { return params.coeffs6[lane]; }
        default: { return params.coeffs7[lane]; }
    }
}

fn dot_basis_channel(basis: array<f32, 10>, channel: u32) -> f32 {
    var sum = 0.0;
    for (var row = 0u; row < 10u; row = row + 1u) {
        sum = sum + basis[row] * coeff(row * 3u + channel);
    }
    return max(sum, 0.0);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let pixel = global_id.x + global_id.y * params.dispatch_width;
    if (pixel >= params.pixel_count) {
        return;
    }

    let base = pixel * 3u;
    let eps = 0.00000001;
    let log2_to_log10 = 0.3010299956639812;

    let tr = max(input_values[base] / params.default_light, eps);
    let tg = max(input_values[base + 1u] / params.default_light, eps);
    let tb = max(input_values[base + 2u] / params.default_light, eps);

    let dr = max(-log2(tr) * log2_to_log10 - params.dmin.x, 0.0);
    let dg = max(-log2(tg) * log2_to_log10 - params.dmin.y, 0.0);
    let db = max(-log2(tb) * log2_to_log10 - params.dmin.z, 0.0);

    let basis = array<f32, 10>(
        dr,
        dg,
        db,
        dr * dr,
        dg * dg,
        db * db,
        dr * dg,
        dr * db,
        dg * db,
        1.0,
    );

    output_values[base] = dot_basis_channel(basis, 0u);
    output_values[base + 1u] = dot_basis_channel(basis, 1u);
    output_values[base + 2u] = dot_basis_channel(basis, 2u);
}
