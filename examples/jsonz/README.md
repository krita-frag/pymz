# jsonz

`jsonz` is a standalone pymz example project. It demonstrates a Zig extension
module with functions, keyword arguments, a custom exception, a Python-visible
class, generated C API glue, and generated `.pyi` stubs.

## Layout

- `src/jsonz.zig` contains the Zig extension module.
- `build.zig` compiles the extension and emits `jsonz.pyi`.
- `pymz/` is the runtime package dependency.
- `pymz-build/` is the shared Zig build helper package.
- `setup.py` drives the Python packaging-compatible build path.
- `tests/` contains the Python behavior tests.

## Build

```bash
python setup.py build_ext --inplace
PYTHONPATH=zig-out/lib python -m pytest tests -q
```

Build a wheel through the `pymz-tool` CLI:

```bash
PYTHONPATH=../../tools python -m pymz_tool build --module jsonz --version 0.1.0 --release -o dist
```

Python 2.7 is validated through the repository Nix shell:

```bash
NIXPKGS_ALLOW_INSECURE=1 nix develop ../../#py27 --impure
zig build example -Dpython-version=2.7
PYTHONPATH=zig-out/lib python2.7 -c "import jsonz; assert jsonz.validate_json('{}') is True"
```
