import os
import sys

from . import _loader

if sys.version_info[0] >= 3:
    _loader.load_jsonz_extension()
    from ._jsonz import *  # noqa: F401,F403
    from ._jsonz import __version__  # noqa: F401
else:
    from ._jsonz import *  # noqa: F401,F403
    from ._jsonz import __version__  # noqa: F401
