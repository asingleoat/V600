# Scanner Fixtures

Scanner fixtures are replay evidence for Linux SANE wrapper behavior and the
future macOS interpreter backend. They should let tests cover parsing, command
construction, structured events, metadata sidecars, and error classification
without requiring scanner hardware.

Subdirectories:

- `scanimage-list/`: captured or live-style `scanimage -L` output.
- `scanimage-help/`: captured or minimal `scanimage --help` output for
  flatbed and TPU sources.
- `stderr/`: backend stderr samples for structured error classification.
- `events/`: JSONL scanner event streams emitted by the Zig CLI.
- `metadata/`: small scanner sidecar metadata JSON examples.

When adding a fixture, record the command or source that generated it in the
nearest README or in `plan.md`'s verification log.
