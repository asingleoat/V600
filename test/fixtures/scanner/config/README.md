Scanner config fixtures generated from `v600/config/settings.py`.

These files are small Python-oracle fixtures for `epdaughter_config.toml`
behavior. They capture exact `save_config()` output, including the leading
blank line, section order, comments, and the active-vs-commented distinction.

Generation commands used during the Zig rewrite:

```sh
python3 - <<'PY'
from pathlib import Path
import importlib.util, tempfile

spec = importlib.util.spec_from_file_location("settings", "v600/config/settings.py")
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)

with tempfile.TemporaryDirectory() as td:
    path = Path(td) / "epdaughter_config.toml"
    settings.CONFIG_FILE = path
    settings.save_config({})
    print(path.read_text())

    settings.save_config({"dpi": 1600, "mode": "ir", "sel_w_in": 1.25, "autoselect": False})
    print(path.read_text())

    settings.save_config({"preview_dpi": 400, "sel_w_in": 0.0})
    print(path.read_text())
PY
```

The Zig app has since added a `[roll]` section (the current roll's name),
appended to all three fixtures by hand; the Python settings never had it.
