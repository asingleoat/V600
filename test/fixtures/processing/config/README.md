Processing config TOML fixtures generated from the frozen Python
`scratchndent.config.save_config()` implementation.

Oracle command pattern:

```python
from pathlib import Path
import tempfile
import scratchndent.config as c

with tempfile.TemporaryDirectory() as d:
    c.CONFIG_FILE = Path(d) / "scratchndent_config.toml"
    c._CONFIG.clear()
    c.save_config({...})
    print(c.CONFIG_FILE.read_text())
```

Fixtures:

- `default-save.toml`: `save_config({})`
- `partial-save.toml`: selected top-level, dust-removal, render, list, and
  boolean values.
- `merged-save.toml`: a second `save_config()` call over the partial in-memory
  config, covering update-in-place ordering and newly appended top-level keys.
- `custom-stock-save.toml`: `save_config()` with a config-defined
  `[stocks.custom_c41]` profile, covering Python's manual custom-stock TOML
  workflow.

Since the Python freeze the Zig app has changed the `[render]` section and
the built-in stock profiles, and these files were rewritten from the Zig
serializer to match: `render_curve_k` is gone; `render_contrast` (now 1.8),
the percentile, exposure, temperature, and tint comments describe the
current display transform; `auto_white_balance`, `film_gamma`, `film_toe`,
and `dye_crosstalk` are new; and the commented `kodak_gold` and
`kodak_portra` rows hold the measured channel balances.
