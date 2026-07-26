"""Exception hierarchy for pymz-tool.

All pymz-tool build/configuration failures raise a ``PymzError`` subclass so
callers (CLI, PEP 517 backend, tests) can distinguish pymz failures from
generic ``RuntimeError``/``OSError`` without broad ``except Exception`` blocks.
"""
from __future__ import absolute_import


class PymzError(Exception):
    """Base class for all pymz-tool failures."""


class PymzConfigError(PymzError):
    """Raised when project configuration (pymz.json/pyproject.toml) is invalid
    or insufficient to describe a build (e.g. no modules declared)."""


class PymzBuildError(PymzError):
    """Raised when a ``zig build`` invocation or artifact collection fails."""


class PymzManifestError(PymzError):
    """Raised when a build manifest cannot be written or is malformed at load
    time."""
