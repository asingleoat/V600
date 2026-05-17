# `scanimage --help` Fixtures

Use this directory for SANE option help. Full captured help can be large and
slow to generate, so tests may also use minimal live-style fragments when they
only need specific parser behavior.

Typical generation commands:

```sh
nix develop path:. -c scanimage-v600 --device-name epkowa:interpreter:001:017 --source Flatbed --help
nix develop path:. -c scanimage-v600 --device-name epkowa:interpreter:001:017 --source "Transparency Unit" --help
```
