# Scanner Companion Server

`v600-zig serve` lets the browser webapp scan. It binds `127.0.0.1`, serves
the staged webapp, and runs scans through the same Linux scanner runtime as
the CLI (`scanner.linux.Runtime`: patched epkowa SANE, TPU, IR pass), exposed
as a small JSON job API. Linux only.

Status: tested against a fake `scanimage` only; no live scan through the
companion has been recorded. It has known bugs, including no protection
against cross-site requests; see Known issues.

## Usage

```sh
zig build wasm-webapp
./zig-out/bin/v600-zig serve [--port 8433] [--webapp-dir zig-out/webapp] \
                             [--out-dir scans] [--scanimage PATH]
```

Open `http://127.0.0.1:8433/`. `--scanimage` replaces the scanner
executable, for hardware-free testing. On startup the server prints one
`{"event":"companion-ready","schema":"v600.companion.event.v1",...}` line.

## API

Bodies are JSON. Scan progress reuses the `v600.scanner.event.v1` event
objects unchanged; the companion adds `companion-status` lines to the same
stream and wraps responses in the `v600.companion.api.v1` schema.

| Method and path | Behavior |
| --- | --- |
| `GET /api/status` | `{schema, service, version, job}`; `job` is `null` before the first scan, else `{id, status, error?}`. |
| `GET /api/devices` | `{schema, devices: [{name, vendor, model, kind}], error?}`. Discovery failures fill `error`. Runs `scanimage -L`, which blocks the server while it runs. |
| `POST /api/scan` | Body `{dpi?, source?, kind?, depth?, device?, x?, y?, width?, height?}`; defaults match `v600-zig scanner scan` (400 dpi, tpu, rgb, 16-bit). `kind` is `rgb`, `gray`, `ir`, or `rgb+ir` (alias `rgb_ir`). Returns `{schema, job, status, output}`; `409` while a job runs. One job at a time. No LUT or preview-scan options. |
| `GET /api/scan/<id>/events?from=N` | `{schema, job, status, next, events: [...]}` from index `N`. Poll with `from=next` until `status` is `complete`, `failed`, or `cancelled`. |
| `GET /api/scan/<id>/file` | The combined scan TIFF (`image/tiff`) once complete; `409` before that. |
| `GET /api/scan/<id>/metadata` | The sidecar JSON once complete. |
| `POST /api/scan/<id>/cancel` | Creates the job's cancel file, which the scan runtime polls; `409` when no job is running. |
| other `GET` | Static file from `--webapp-dir`; `/` serves `index.html`; `..` components are rejected. |

Outputs go to `--out-dir` as `companion_scan_<id>.tiff` plus a `.json`
sidecar; the cancel file is `companion_scan_<id>.tiff.cancel`.

## Webapp Scan tab

`web/companion.mjs` is the browser client: status probe, scan request,
polled `runScanJob`, file and metadata download. The Scan tab uses it and
hands the finished TIFF to the Process pipeline as if the file had been
picked by hand. When `/api/status` is unreachable (static hosting without
the companion), the tab shows setup instructions and the rest of the app
works.

## Tests

`zig build companion-smoke --summary all` starts the server against a fake
`scanimage` (a shell script that needs ImageMagick `magick`), checks static
serving and each endpoint, runs an `rgb+ir` job through polled events, and
parses the downloaded TIFF with `web/tiff.mjs`. It does not cover cancelling
a running job, the `409` on concurrent scans, or the Scan tab DOM code.

## Known issues

- No Origin, Host, or content-type check. Binding to loopback does not stop
  a web page in the same browser from sending a simple cross-site POST that
  starts or cancels a scan, and DNS rebinding could read scan files.
- `startScan` can return an error while holding the job mutex, leaving the
  server wedged with the job stuck in `running`.
- Job ids restart at 1 on every launch, so earlier `companion_scan_0001.tiff`
  files are overwritten.
- The job thread publishes its terminal status before appending the final
  status line, and `startScan` joins the previous job thread while holding
  the mutex that thread needs to append that line.
- `/file` reads up to 2 GiB into memory.
