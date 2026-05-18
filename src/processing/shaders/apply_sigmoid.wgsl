struct SigmoidParams {
    white_target: f32,
    paper_exposure: f32,
    film_fog: f32,
    film_power: f32,
    paper_power: f32,
    count: u32,
    dispatch_width: u32,
    pad1: u32,
};

@group(0) @binding(0) var<storage, read> input_values: array<f32>;
@group(0) @binding(1) var<storage, read_write> output_values: array<f32>;
@group(0) @binding(2) var<uniform> params: SigmoidParams;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x + global_id.y * params.dispatch_width;
    if (index >= params.count) {
        return;
    }

    let clamped = max(input_values[index], 0.0);
    let film_response = pow(params.film_fog + clamped, params.film_power);
    let ratio = film_response / (params.paper_exposure + film_response);
    let paper_response = params.white_target * pow(ratio, params.paper_power);
    output_values[index] = select(params.white_target, paper_response, paper_response == paper_response);
}
