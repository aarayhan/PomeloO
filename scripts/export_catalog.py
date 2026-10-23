"""Write docs/catalog.json: every input format with its conversions and tools, plus the tool and action
tables. The PomeloO website reads it at build time, so its format lists always match the app.

    python scripts/export_catalog.py
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pomeloo import __version__  # noqa: E402
from pomeloo.catalog import ACTIONS, TOOLS, all_input_exts, kind, targets, tools  # noqa: E402

out = {
    "version": __version__,
    "formats": {e: {"kind": kind(e) or "document", "to": targets(e), "tools": tools(e, 1),
                    "tools_many": [t for t in tools(e, 2) if t not in tools(e, 1)]}
                for e in sorted(all_input_exts())},
    "tools": {t: {"short": v[0], "name": v[1]} for t, v in TOOLS.items()},
    "actions": {a: {"short": v[0], "name": v[1], "about": v[2]} for a, v in ACTIONS.items()},
}
path = Path(__file__).resolve().parent.parent / "docs" / "catalog.json"
path.write_text(json.dumps(out, indent=1), encoding="utf-8")
print(f"{path}: {len(out['formats'])} formats, {len(out['tools'])} tools, {len(out['actions'])} actions")
