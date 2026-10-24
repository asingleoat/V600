# Test Fixtures

Committed fixtures are small deterministic inputs and expected outputs: the
regression baselines the Zig tests hold the code to. Many were generated
from the frozen Python implementation; each folder's README says how. When
output changes on purpose, update the affected expectations in the same
commit and say what changed (AGENTS.md).

Tiny TIFF or binary fixtures are fine when they are small enough to review
by their sidecar metadata.

Do not commit full-resolution scanner TIFFs, export outputs, or other large
binary files here without explicit approval. Large local evidence belongs in
`scans/`, `frames/`, or `/tmp/cerealgrain-*`, described in the commit
message.
