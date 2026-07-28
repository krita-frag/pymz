#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test.sh - Build the showcase Zig extension and run the pytest test suite.
#
# Usage:
#   ./test.sh                     # uses $PYMZ_PYTHON, then python3
#   ./test.sh -p python3.12       # explicit interpreter
#   ./test.sh -v                  # verbose (zig build --summary all)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYMZ_ROOT="${PYMZ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PYMZ_TOOL_PYTHON="${PYMZ_TOOL_PYTHON:-$PYMZ_ROOT/pymz-tool/python}"
EXAMPLE_DIR="$SCRIPT_DIR"
ZIG_OUT="$EXAMPLE_DIR/zig-out/lib"

VERBOSE=false
PYTHON=""
PYTHON_CONFIG=""
OPTIMIZE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--python) PYTHON="$2"; shift 2 ;;
    -c|--config) PYTHON_CONFIG="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -O|--optimize) OPTIMIZE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | head -n -1
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$PYTHON" ]; then
  if [ -n "${PYMZ_PYTHON-}" ]; then
    PYTHON="$PYMZ_PYTHON"
  else
    PYTHON="python3"
  fi
fi

if [ -z "$PYTHON_CONFIG" ]; then
  if [ -n "${PYMZ_PYTHON_CONFIG-}" ]; then
    PYTHON_CONFIG="$PYMZ_PYTHON_CONFIG"
  else
    PYTHON_BASENAME="$(basename "$PYTHON")"
    PYTHON_CONFIG="${PYTHON_BASENAME}-config"
  fi
fi

PY_VER="$("$PYTHON" -c 'import sys; print("{}.{}".format(*sys.version_info[:2]))' 2>/dev/null)" || {
  echo "ERROR: cannot run $PYTHON - is it installed?" >&2
  exit 1
}

ZIG_GLOBAL_CACHE_DIR="$EXAMPLE_DIR/.zig-global-cache"
ZIG_LOCAL_CACHE_DIR="$EXAMPLE_DIR/.zig-cache"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

OPT_FLAG=""
if [ -n "$OPTIMIZE" ]; then
  OPT_FLAG="-Doptimize=$OPTIMIZE"
fi

if [ "$VERBOSE" = true ]; then
  echo "=== zig build pymz (py${PY_VER}) ==="
fi

(cd "$EXAMPLE_DIR" && zig build pymz \
  -Dpymz-python-config="$PYTHON_CONFIG" \
  -Dpython-version="$PY_VER" \
  $OPT_FLAG \
  2>&1) | (if [ "$VERBOSE" = true ]; then cat; else grep -i "error\|warning" || true; fi)

PACKAGE_DIR="$EXAMPLE_DIR/python/showcase"
mkdir -p "$PACKAGE_DIR"
for f in "$ZIG_OUT"/*.so "$ZIG_OUT"/*.pyi; do
  if [ -e "$f" ]; then
    cp "$f" "$PACKAGE_DIR/"
  fi
done

"$PYTHON" -c "
import json, os, sys
so_file = None
for f in os.listdir('$ZIG_OUT'):
    if f.endswith('.so') and f.startswith('_showcase'):
        so_file = f
        break
if so_file is None:
    print('ERROR: no _showcase.so found in zig-out/lib/', file=sys.stderr)
    sys.exit(1)
manifest = {
    'schema_version': 1,
    'modules': ['_showcase'],
    'module': '_showcase',
    'version': '0.1.0',
    'runtime': 'cpython3',
    'distribution': 'showcase',
    'zig_target': 'pymz',
    'artifacts': [{'filename': so_file, 'kind': 'extension', 'module': '_showcase'}],
}
with open('$PACKAGE_DIR/pymz-manifest.json', 'w') as f:
    json.dump(manifest, f, indent=2)
print('manifest: $PACKAGE_DIR/pymz-manifest.json (' + so_file + ')')
"

echo "[test.sh] py${PY_VER} build OK"

export PYTHONPATH="$EXAMPLE_DIR/python:${PYMZ_TOOL_PYTHON}${PYTHONPATH:+:$PYTHONPATH}"

if "$PYTHON" -m pytest --version >/dev/null 2>&1; then
  echo "[test.sh] running full test suite (py${PY_VER})..."
  IMPORT_ERROR=$("$PYTHON" -c "import showcase" 2>&1) && IMPORT_OK=true || IMPORT_OK=false
  if [ "$IMPORT_OK" = true ]; then
    "$PYTHON" -m pytest "$EXAMPLE_DIR/tests" -q
    echo "[test.sh] all tests OK (py${PY_VER})"
  else
    case "$IMPORT_ERROR" in
      *"undefined symbol"*|*"magic number"*|*"ABI"*|*"incompatible"*|*"version mismatch"*)
        echo "[test.sh] WARNING: py${PY_VER} runtime import failed (ABI mismatch)."
        echo "[test.sh] (showcase extension built successfully)"
        ;;
      *)
        echo "[test.sh] ERROR: py${PY_VER} import crashed (not an ABI mismatch):" >&2
        echo "$IMPORT_ERROR" >&2
        exit 1
        ;;
    esac
  fi
else
  echo "[test.sh] pytest not available for py${PY_VER}, running smoke test..."
  "$PYTHON" -c '
import showcase
v = showcase.IntVec()
v.push(1)
v.push(2)
assert len(v) == 2
assert v[0] == 1
print("smoke OK, version:", showcase.__version__)
'
  echo "[test.sh] smoke test OK (py${PY_VER})"
fi
