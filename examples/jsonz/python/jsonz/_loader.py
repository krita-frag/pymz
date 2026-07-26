"""Runtime loader shim with a Python 2-compatible static fallback."""

import os
import sys

if sys.version_info[0] >= 3:
    from pathlib import Path

    from pymz_tool.loader import load_extension

    def load_jsonz_extension():
        """Load the matching variant on Python 3."""
        load_extension(package_dir=Path(__file__).parent)
else:
    def load_jsonz_extension():
        """Keep Python 2 on its directly importable ``_jsonz.so`` artifact."""
        package_dir = os.path.dirname(__file__)
        candidates = [
            os.path.join(package_dir, "_jsonz.so"),
            os.path.join(package_dir, "_jsonz.pyd"),
        ]
        if not any(os.path.exists(path) for path in candidates):
            raise ImportError("Python 2 extension artifact not found in %s" % package_dir)
