# Test Fixtures

Committed fixtures in this tree are small deterministic inputs or expected
outputs used to keep the Zig rewrite aligned with the frozen Python
implementation.

Tiny TIFF or binary fixtures are allowed when they are generated from a recorded
Python oracle and are small enough to review by sidecar metadata.

Do not commit full-resolution scanner TIFFs, export outputs, or other large
binary files here without explicit approval. Large local evidence belongs in
`scans/`, `frames/`, or `/tmp/v600-*` and should be described in `plan.md` or
the task summary instead.
