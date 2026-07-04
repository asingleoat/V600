// Browser client for the local scanner companion server (v600-zig serve).
// The protocol contract lives in docs/SCANNER_COMPANION.md: scan progress is
// the native v600.scanner.event.v1 stream plus companion-status envelope
// lines, polled with a cursor. Every function takes an injectable fetch so
// the headless companion smoke can drive this module against a live server.

export const companionApiSchema = "v600.companion.api.v1";

export const scanSources = Object.freeze(["tpu", "flatbed"]);
export const scanKinds = Object.freeze(["rgb+ir", "rgb", "gray", "ir"]);
export const scanDpis = Object.freeze([400, 800, 1600, 3200]);

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function companionJson(response) {
  const body = await response.json();
  if (!response.ok) {
    throw new Error(body?.error ?? `companion request failed with ${response.status}`);
  }
  if (body?.schema !== companionApiSchema) {
    throw new Error(`unexpected companion response schema: ${body?.schema}`);
  }
  return body;
}

export async function companionStatus(fetchFn = fetch, base = "") {
  try {
    const response = await fetchFn(`${base}/api/status`);
    if (!response.ok) return null;
    const status = await response.json();
    if (status?.schema !== companionApiSchema) return null;
    return status;
  } catch {
    return null;
  }
}

export async function companionDevices(fetchFn = fetch, base = "") {
  const response = await fetchFn(`${base}/api/devices`);
  return companionJson(response);
}

export function buildScanRequestBody({
  dpi = 400,
  source = "tpu",
  kind = "rgb+ir",
  device = null,
  x = null,
  y = null,
  width = null,
  height = null,
} = {}) {
  if (!Number.isInteger(dpi) || dpi <= 0) throw new Error(`invalid scan dpi: ${dpi}`);
  if (!scanSources.includes(source)) throw new Error(`invalid scan source: ${source}`);
  if (!scanKinds.includes(kind)) throw new Error(`invalid scan kind: ${kind}`);
  const body = { dpi, source, kind };
  if (device) body.device = device;
  for (const [name, value] of [["x", x], ["y", y], ["width", width], ["height", height]]) {
    if (value === null || value === undefined || value === "") continue;
    const numeric = Number(value);
    if (!Number.isFinite(numeric) || numeric < 0) throw new Error(`invalid scan area ${name}: ${value}`);
    body[name] = numeric;
  }
  return body;
}

export async function startScan(body, fetchFn = fetch, base = "") {
  const response = await fetchFn(`${base}/api/scan`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return companionJson(response);
}

export async function pollScanEvents(job, from, fetchFn = fetch, base = "") {
  const response = await fetchFn(`${base}/api/scan/${job}/events?from=${from}`);
  return companionJson(response);
}

export async function cancelScan(job, fetchFn = fetch, base = "") {
  const response = await fetchFn(`${base}/api/scan/${job}/cancel`, { method: "POST" });
  return companionJson(response);
}

export async function fetchScanFile(job, fetchFn = fetch, base = "") {
  const response = await fetchFn(`${base}/api/scan/${job}/file`);
  if (!response.ok) throw new Error(`scan file request failed with ${response.status}`);
  return response.arrayBuffer();
}

export async function fetchScanMetadata(job, fetchFn = fetch, base = "") {
  const response = await fetchFn(`${base}/api/scan/${job}/metadata`);
  if (!response.ok) throw new Error(`scan metadata request failed with ${response.status}`);
  return response.json();
}

export async function runScanJob({
  body,
  fetchFn = fetch,
  base = "",
  onEvent = () => {},
  pollMs = 250,
  sleep = defaultSleep,
  timeoutMs = 10 * 60 * 1000,
}) {
  const started = await startScan(body, fetchFn, base);
  let next = 0;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const page = await pollScanEvents(started.job, next, fetchFn, base);
    for (const event of page.events) onEvent(event);
    next = page.next;
    if (page.status !== "running") {
      return { job: started.job, status: page.status, output: started.output };
    }
    await sleep(pollMs);
  }
  throw new Error("scan job timed out");
}

export function describeScanEvent(event) {
  switch (event.event) {
    case "companion-status":
      return event.error ? `job ${event.status}: ${event.error}` : `job ${event.status}`;
    case "startup":
      return `scanner backend ${event.backend}`;
    case "device-discovery":
      return event.selected_device ? `device ${event.selected_device}` : "device discovery";
    case "scan-start":
      return `${event.kind} pass at ${event.effective_dpi} dpi`;
    case "progress":
      return `progress ${event.percent}%`;
    case "scan-complete":
      return `pass complete: ${event.output}`;
    case "scan-cancelled":
      return "scan cancelled";
    case "scan-error":
      return `scan error: ${event.detail ?? event.kind ?? "unknown"}`;
    case "timing":
      return `${event.stage} ${event.elapsed_us} us`;
    default:
      return event.event;
  }
}
