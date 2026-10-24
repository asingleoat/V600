# Scanner Fixtures

Scanner fixtures are captured scanner output, replayed so tests cover the
Linux SANE path's parsing and error classification and the macOS
interpreter's protocol without scanner hardware.

Subdirectories:

- `scanimage-list/`: captured or live-style `scanimage -L` output.
- `scanimage-help/`: captured or minimal `scanimage --help` output for
  flatbed and TPU sources.
- `stderr/`: backend stderr samples for structured error classification.

When adding a fixture, record the command or source that generated it in the
nearest README.
