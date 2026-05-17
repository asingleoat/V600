# `scanimage -L` Fixtures

Use this directory for raw device-list output. Keep files close to the real
command output because parsers should be tested against the same punctuation
and quoting SANE emits.

Typical generation command:

```sh
nix develop path:. -c scanimage -L
```
