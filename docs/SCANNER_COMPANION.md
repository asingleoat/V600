# Scanner Companion Server

`v600-zig serve` is the local companion that gives the browser webapp the
film acquisition pipeline. It binds `127.0.0.1` only, serves the staged
static webapp, and exposes the unmodified native scanner stack
(`scanner.linux.Runtime`: patched epkowa SANE, gamma LUT upload, IR pass)
through a small JSON job API. Because the webapp and the API share the same
loopback origin there is no CORS surface and no Private Network Access
preflight; the server is not reachable from other machines.

## Usage

```
zig build wasm-webapp
./zig-out/bin/v600-zig serve [--port 8433] [--webapp-dir zig-out/webapp]
                             [--out-dir scans] [--scanimage PATH]
```

The browser opens `http://127.0.0.1:8433/`. `--scanimage` overrides the
scanner executable exactly like the runtime test override and exists for
hardware-free testing.

On startup the server prints one
`{"event":"companion-ready","schema":"v600.companion.event.v1",...}` line.

## API

All bodies are JSON. Scan progress reuses the `v600.scanner.event.v1` event
objects unchanged; the companion adds `companion-status` lines in the same
stream and wraps responses in the `v600.companion.api.v1` schema.

| Method and path | Behavior |
| --- | --- |
| `GET /api/status` | `{schema, service, version, job}`; `job` is `null` before the first scan, else `{id, status, error?}`. |
| `GET /api/devices` | `{schema, devices: [{name, vendor, model, kind}], error?}`. Discovery failures fill `error` instead of failing the request. |
| `POST /api/scan` | Body `{dpi?, source?, kind?, depth?, device?, x?, y?, width?, height?}` (defaults match `v600-zig scanner scan`: dpi 400, tpu, rgb, 16-bit). Returns `{schema, job, status, output}`; `409` while a job is running. One job at a time. |
| `GET /api/scan/<id>/events?from=N` | `{schema, job, status, next, events: [...]}` replaying buffered event objects from index `N`. Poll with `from=next` until `status` is terminal (`complete`, `failed`, `cancelled`). |
| `GET /api/scan/<id>/file` | Combined scan TIFF bytes (`image/tiff`) once complete; `409` before that. |
| `GET /api/scan/<id>/metadata` | Sidecar JSON once complete. |
| `POST /api/scan/<id>/cancel` | Creates the job's cancel file (the scan runtime polls it); `409` when the job is not running. |
| anything else (`GET`) | Static webapp file from `--webapp-dir`; `/` serves `index.html`; `..` components are rejected. |

Scan outputs are written to `--out-dir` as
`companion_scan_<id>.tiff` plus the `.json` sidecar; the cancel file is
`companion_scan_<id>.tiff.cancel`.

## Validation

`zig build companion-smoke --summary all` runs the hardware-free contract
smoke: it starts the server against a fake `scanimage`, checks static
serving and every endpoint above, drives a complete `rgb+ir` job through
polled events, and parses the downloaded TIFF with the browser TIFF reader
(`web/tiff.mjs`). Live-hardware evidence through the browser Scan tab is a
recorded Phase 15 follow-up for when the V600 is reconnected.

## Webapp Scan Tab

`web/companion.mjs` is the browser client for this API (status probe, scan
request builder, cursor-polled `runScanJob`, file/metadata download, event
formatting); the Scan tab in the webapp drives it and hands the finished
TIFF straight into the Process pipeline, exactly as if the file had been
picked manually. When `/api/status` is unreachable (static hosting without
the companion) the tab shows setup instructions and everything else keeps
working. The companion smoke exercises this module against the live server
in addition to the raw HTTP contract.
