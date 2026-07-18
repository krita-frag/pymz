# pymz

`pymz` is a Zig-first toolkit for building Python extension modules with a
small public API and a compatibility-heavy runtime.

It is designed for projects that need:

- CPython 2.7 through 3.x support.
- Per-`python-version` / per-platform / per-ABI wheel artifacts.
- Ordinary Zig `fn` and `struct` declarations, with comptime reflection
  generating the C API glue.
- A simple developer workflow instead of a large handwritten binding layer.

## Design

The project is organized around four goals:

1. Compatibility: Python 2.7 and 3.x remain first-class targets.
2. Multi-distribution: each Python version and platform gets its own artifact.
3. Extensibility: Zig code stays Zig code; the binding layer is generated.
4. Usability: the public API is intentionally small and explicit.

The repository is split into the core toolkit and a standalone example:

- `pymz/` contains the Zig runtime and public API package.
- `pymz-build/` contains the reusable Zig build helper package.
- `tools/pymz_tool/` contains the Python build tool, wheel writer, and scaffold CLI.
- `setup.py` installs the `pymz-tool` Python build tool for legacy Python packaging.
- `build.zig` is the workspace build file.
- `examples/` contains standalone example packages.
- `examples/jsonz/` is an independent `jsonz` project with its own `setup.py`,
  `build.zig`, `pymz/`, `pymz-build/`, `src/`, and `tests/`.

## Example

```zig
const pymz = @import("pymz");

fn addImpl(a: i64, b: i64) pymz.Result(i64) {
    return @intCast(a + b);
}

pub const pymz_module = pymz.module("demo", .{
    .__pymz_param_names__ = .{
        .add = "a, b",
    },
    .add = pymz.function(addImpl, "Add two integers."),
}, null, "Demo module.");

comptime {
    _ = pymz_module;
}
```

Protocol hooks can be attached explicitly:

```zig
pub const __repr__ = pymz.Repr(reprImpl);
```

## Build

Install the `pymz-tool` build tool from the repository root:

```bash
python setup.py install
```

Build and test the standalone `jsonz` example:

```bash
cd examples/jsonz
python setup.py build_ext --inplace
PYTHONPATH=zig-out/lib python -m pytest tests -q
```

Build a `jsonz` wheel from the example project:

```bash
cd examples/jsonz
python -m pymz_tool build --module jsonz --version 0.1.0 --release -o dist
```

## Python 2.7

Python 2.7 support is kept in the build matrix and validated through the Nix
shell defined in `flake.nix`.
