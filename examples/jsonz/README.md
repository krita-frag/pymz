# jsonz

`jsonz` is a mixed Python + Zig example. The Python package lives under
`python/jsonz/`, and the Zig extension is built as `jsonz._jsonz`.

## Layout

- `python/jsonz/` contains the importable Python package shim.
- `src/jsonz.zig` contains the Zig extension module.
- `build.zig` compiles the extension and emits `_jsonz.pyi`.
- `setup.py` uses the shared `pymz_setup` helper to build Zig output and copy
  the compiled extension and stub into the Python package for wheel builds.
- `tests/` contains the Python behavior tests.

## Build

```bash
python setup.py build_ext --inplace
PYTHONPATH=python python -m pytest tests -q
```

Build a wheel that bundles the Python package and the compiled Zig extension:

```bash
python setup.py bdist_wheel
```

For local extension development, edit `src/jsonz.zig`, rerun `zig build`, then
rerun `python setup.py build_ext --inplace`.
