# jsonz

`jsonz` is a mixed Python + Zig example. The Python package lives under
`python/jsonz/`, and the Zig extension is built as `jsonz._jsonz`.

## Layout

- `python/jsonz/` contains the importable Python package shim.
- `src/jsonz.zig` contains the Zig extension module.
- `build.zig` compiles the extension and emits `_jsonz.pyi`.
- `tests/` contains the Python behavior tests.

## Build

```bash
python -m build --wheel --no-isolation
python -m pip install --force-reinstall --no-deps dist/*.whl
python -m pytest tests -q
```

Build a wheel that bundles the Python package and the compiled Zig extension:

```bash
python -m build --wheel --no-isolation
```

For local extension development, edit `src/jsonz.zig`, then rerun
`python -m build --wheel --no-isolation` or `python -m pip install -e .`.
