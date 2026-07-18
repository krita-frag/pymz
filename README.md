# pymz

用 Zig 写 Python 扩展：编译期反射自动生成 CPython C API 胶水代码，
支持 CPython 2.7 ~ 3.14，直接产出 wheel。

## 前置依赖

- **Zig** `0.16.0-dev.2979+e93834410`
- **Python** 2.7 / 3.8+
- **setuptools** ≥ 42

## 快速开始

```bash
# 1. 构建 pymz-tool
cd pymz-tool && zig build

# 2. 构建 jsonz 示例 wheel
cd ../examples/jsonz
PYMZ_PYTHON=$(which python3) \
    ../../pymz-tool/zig-out/bin/pymz-tool build \
        --module _jsonz --distribution jsonz --version 0.1.0 \
        --zig-target example --package-dir python --release -o dist

# 3. 安装并测试
pip install --force-reinstall --no-deps dist/*.whl
python -c "import jsonz; print(jsonz.validate_json('[1, 2, 3]'))"  # => True
pytest tests/
```

## 写一个扩展

```zig
const pymz = @import("pymz");

fn addImpl(a: i64, b: i64) pymz.Result(i64) {
    return @intCast(a + b);
}

pub const pymz_module = pymz.module("demo", .{
    .__pymz_param_names__ = .{ .add = "a, b" },
    .add = pymz.function(addImpl, "Add two integers."),
}, null, "Demo module.");

comptime { _ = pymz_module; }
```

完整示例见 [`examples/jsonz`](examples/jsonz)。

## `pymz-tool` 命令

```bash
# 为当前 Python 构建单个 wheel
pymz-tool build --module _foo --distribution foo --version 0.1.0 \
    --zig-target foo --package-dir python --release -o dist

# 为多个 Python 版本批量构建
pymz-tool matrix --module _foo --distribution foo --version 0.1.0 \
    --python-versions 3.9,3.10,3.11,3.12 --release -o dist
```

常用参数：`--module`、`--distribution`、`--package-dir`、`--version`、
`--release`、`--zig-target`、`--python-versions`（matrix 必填）、
`-o/--out`。环境变量 `PYMZ_PYTHON` 指定目标解释器。运行
`pymz-tool --help` 查看完整列表。

## 公共 API

| 名称 | 说明 |
| --- | --- |
| `pymz.module(name, members, exc, doc)` | 声明 Python 模块。 |
| `pymz.function(fn, doc)` | 暴露 Zig `fn` 为 Python 函数。 |
| `pymz.kwFunction(fn, doc)` | 同上，支持关键字参数。 |
| `pymz.class("Name", spec, doc)` | 把 Zig struct 暴露为 Python 类。 |
| `pymz.exception(.value_error, "msg")` | 声明自定义异常。 |
| `pymz.Result(T)` | 返回类型，等价于 `!T`。 |
| `pymz.Value` | 不透明的 `PyObject *`。 |
| `pymz.none/boolean/integer/floating/string` | 构造 Python 对象。 |
| `pymz.list(n)` / `pymz.dict()` | 构造容器。 |

详见 [`pymz/src/api.zig`](pymz/src/api.zig)。

## 测试

```bash
cd pymz-tool && zig build test --summary all   # Zig 单元测试
python -m pytest pymz_setup/tests/ -v           # Python 单元测试
python -m pytest examples/jsonz/tests/ -v       # 端到端测试
```

## 许可证

MIT。
