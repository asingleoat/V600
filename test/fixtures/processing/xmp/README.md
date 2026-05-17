Small darktable XMP sidecar fixtures for parser parity tests.

`darktable-negadoctor-sigmoid.xmp` contains disabled and enabled history
entries for negadoctor, sigmoid, and channelmixerrgb. Tests use it to prove
the parser selects the last enabled module matching the requested operation.

`missing-modules.xmp` is well-formed XML with no enabled negadoctor, sigmoid,
or channelmixerrgb history entries.
