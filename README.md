# pymz

用 Zig 写 Python 扩展：编译期反射自动生成绑定胶水代码，默认后端面向
CPython 2.7 ~ 3.14，直接产出 wheel。当前稳定目标是 CPython 2/3，以及同一份
Zig 源码对多个 Python 版本、平台和 CPython 后端的一键矩阵构建。

## 项目理念

pymz 的核心目标是**一套代码兼容多版本、多平台**：

- **多版本**：同一份 Zig 代码通过 `pymz-tool/core` 的条件编译与兼容性层面向
  CPython 2.x 与 3.x；CPython 2 需要在对应解释器环境中完成构建验证。内置 runtime
  目前稳定支持 CPython；其他解释器必须提供并验证自己的 backend source。
- **多平台**：只要 Zig 支持的目标（Linux、macOS、Windows、musl 等）都能构建，
  并自动生成符合 PEP 425 的 wheel 平台标签。
- **极简与可扩展的平衡**：核心 API 保持最小集合，复杂需求通过模块化
  后端契约、函数描述符选项、PEP 517 构建后端等机制扩展，而不是把功能塞进
  一个臃肿的接口。

## 前置依赖

- **Zig** `0.16.0`
- **Python** 2.7 / 3.8+
- **setuptools** ≥ 61

> 也可使用 direnv + Nix Flake 自动管理以上依赖（见下），无需手动安装。

## 可复现开发环境（推荐）

[direnv](https://direnv.net/) + [Nix Flake](https://nixos.wiki/wiki/Flakes) 实现 **100% 环境可复现**，不污染系统。

### 1. 安装 direnv

```bash
# macOS
brew install direnv

# Linux
# apt install direnv  # Debian/Ubuntu
# pacman -S direnv    # Arch
```

### 2. 配置 direnv shell hook

在 `~/.zshrc`（或 `~/.bashrc`）末尾添加：

```bash
eval "$(direnv hook zsh)"    # zsh 用户
# eval "$(direnv hook bash)" # bash 用户
```

重载配置：

```bash
source ~/.zshrc
```

> 如果使用 Oh My Zsh，direnv 插件也可实现相同效果：`plugins=(direnv)`。

### 3. 进入项目

```bash
cd pymz
direnv allow   # 首次需允许，后续自动加载
```

之后每次 `cd pymz` 都会自动激活 flake 环境。终端会显示：

```
direnv: loading ~/Documents/projects/pymz/.envrc
direnv: using flake . --impure
[pymz] py312: zig 0.16.0, python 3.12.13
        run  ./examples/jsonz/test.sh  to build & test jsonz
```

### 4. 环境说明

环境提供以下工具（Zig 缓存隔离到 `.zig-cache` / `.zig-global-cache`；`PYMZ_PYTHON` 自动指向该 Python；`pymz-tool` CLI 自动可用，无需 `pip install`）：

| 工具 | 版本 | 说明 |
|------|------|------|
| `zig` / `zls` | 0.16.0 | 编译器 + 语言服务器 |
| `python3` | 3.12 | 默认 Python（含 setuptools / pytest / build / pip / wheel） |
| `nix develop .#py27` | 2.7 | 专用 shell 验证 CPython 2 兼容性 |
| `nix develop .#py314` | 3.14 | 专用 shell 验证 CPython 3.14 兼容性 |
| `nix develop .#py311` / `.#py313` | 3.11 / 3.13 | 矩阵内其他版本 |
| `git` / `gnumake` / `ripgrep` | latest | 版本管理 / 构建辅助 / 搜索 |
| `pymz-tool` | — | CLI 自动就绪（`python -m pymz_tool.cli` 封装） |

> **Nix 配置**：若未启用 flakes，在 `nix.conf` 中添加 `experimental-features = nix-command flakes`。

### 5. 验证环境

```bash
# 验证 zig/python 来自 flake 而非系统
zig version            # => 0.16.0
echo "$PYMZ_PYTHON"    # => /nix/store/.../python3.12
echo "$ZIG_LOCAL_CACHE_DIR"  # => .../.zig-cache

# 构建 + 测试 jsonz 示例
cd examples/jsonz && ./test.sh
```

`test.sh` 是 jsonz 构建+测试的唯一入口，支持以下参数：

| 参数 | 说明 |
|------|------|
| (无) | 构建 + 运行完整测试套件 |
| `-v` | 详细输出（zig build 全部日志） |
| `--loader-only` | 跳过构建，只测运行时加载器 |
| `-p python3.14` | 指定 Python 解释器 |
| `-c /path/to/python-config` | 指定 python-config 脚本 |
| `-O ReleaseFast` | 优化构建 |

```bash
# 指定版本测试
./test.sh -p python3.14
nix develop .#py27 --command ./test.sh
```

---

否则请手动安装前置依赖后参考下方常规方式。

## 快速开始

### 方式一：使用 pymz-tool 直接构建（推荐）

项目根目录的 `pymz.json` 是统一的构建矩阵配置，取代零散的命令行参数与环境变量。
`pymz-tool` 会自动读取当前目录下的 `pymz.json`，CLI 标志仍可覆盖其中任意值。

```bash
# 1. 安装 pymz-tool（纯 Python 包）
pip install -e pymz-tool

# 2. 构建 jsonz 示例 wheel
cd examples/jsonz
PYMZ_PYTHON=$(which python3) pymz-tool build

# 3. 安装并测试
python -m pip install --force-reinstall --no-deps dist/*.whl
python -c "import jsonz; print(jsonz.validate_json('[1, 2, 3]'))"  # => True
python -m pytest tests/
```

> 在 direnv 环境中 `pymz-tool` 已自动就绪，无需 `pip install`。

### 方式二：PEP 517 构建后端

```bash
pip install -e pymz-tool
cd examples/jsonz
python -m build --wheel --no-isolation
python -m pip install --force-reinstall --no-deps dist/*.whl
```

`examples/jsonz/pyproject.toml` 声明构建系统和项目元数据：

```toml
[build-system]
requires = ["pymz-tool"]
build-backend = "pymz_tool"

[project]
name = "jsonz"
version = "0.1.0"
```

后端入口只负责单次构建。要同时编译多个后端实现，使用
`pymz-tool matrix` 并配置 `pymz.json` 的 `matrix` 字段。

## 写一个扩展

```zig
const pymz = @import("pymz");
const py = pymz.py;

fn addImpl(a: i64, b: i64) py.value.Result(i64) {
    return @intCast(a + b);
}

pub const pymz_module = py.decl.module("demo", .{
    .add = py.decl.function(addImpl, .{
        .doc = "Add two integers.",
        .signature = "a, b",
    }),
}, null, "Demo module.");

comptime { _ = pymz_module; }
```

完整示例见 [`examples/jsonz`](examples/jsonz)。

### 在 `build.zig` 中自定义链接

`buildProject` 返回主 artifact（`?*std.Build.Step.Compile`），并通过
`BuildHooks` 暴露两个回调点，让你在不 fork pymz 的情况下添加 C 源文件、
链接额外库或挂载额外构建步骤：

```zig
const std = @import("std");
const pymz_tool = @import("pymz-tool");

pub fn build(b: *std.Build) !void {
    const artifact = try pymz_tool.core.buildProject(b, .{
        .module_name = "_mymod",
        .root_source_file = b.path("src/mymod.zig"),
        .hooks = .{
            .configure_module = struct {
                fn run(mod: *std.Build.Module, ctx: pymz_tool.core.HookContext) void {
                    mod.linkSystemLibrary("z", .{});
                    mod.addCSourceFile(.{
                        .file = ctx.b.path("src/shim.c"),
                        .flags = &.{"-O2"},
                    });
                }
            }.run,
        },
    });
    if (artifact) |a| {
        _ = a;
    }
}
```

## 测试

```bash
# Zig 单元测试
cd pymz-tool && zig build test --summary all

# jsonz 端到端测试（开发环境默认）
cd examples/jsonz && ./test.sh

# 指定版本
./test.sh -p python3.14          # py3.14
nix develop .#py27 --command ./test.sh  # py2.7 via nix
```

`test.sh` 完成以下步骤：编译 Zig 扩展、生成运行时清单、运行 pytest 测试套件
（py2.7 运行基础 smoke 测试）。支持 `--loader-only`、`-v`、`-O ReleaseFast` 等参数。

Nix 环境提供可复现的集成检查：

```bash
nix develop . --command bash -c 'cd examples/jsonz && ./test.sh'
nix develop .#py27 --command bash -c 'cd examples/jsonz && ./test.sh'
```

PEP 517 后端的构建流程也会通过 `examples/jsonz/pyproject.toml` 自动覆盖：

```bash
cd examples/jsonz
python -m build --wheel --no-isolation
python -m build --sdist --no-isolation
```

## 配置参考：`pymz.json`

`pymz.json` 是 pymz 项目的 **Python 打包配置** 单一真相源，
只负责 wheel 元数据、解释器发现和构建矩阵。Zig 构建侧的设置（入口文件、
optimize 模式、安装目录、额外链接库等）在 `build.zig` 中声明，不混入
`pymz.json`。

`pymz-tool` 启动时会自动读取当前目录下的 `pymz.json`，
CLI 参数始终可以覆盖配置值。

JSON 示例（只包含构建配置，打包元数据由 `pyproject.toml` / `setup.py` 管理）：

```json
{
    "module": "_jsonz",
    "zig-target": "example",
    "matrix": [
        {
            "runtime": "cpython3",
            "versions": ["3.10", "3.11", "3.12", "3.13"],
            "targets": ["native"]
        },
        {
            "runtime": "cpython2",
            "targets": ["native"]
        }
    ]
}
```

### 顶层字段

| 字段 | 说明 |
|------|------|
| `module` | 扩展模块名（如 `_jsonz`），单模块时使用 |
| `modules` | 多模块列表，每个条目 `{"name": "_foo", "zig-target": "step"}` |
| `zig-target` | 默认 `zig build` 步骤名（如 `example`） |
| `matrix` | 构建矩阵，每个条目一组 `runtime` + `version(s)` + `targets` + `platform_tags` |

### 矩阵条目字段

每个矩阵条目还可以指定以下字段，把交叉编译所需的解释器信息固化到配置里：

| 字段 | 构建选项 | 说明 |
|------|----------|------|
| `python` | — | 目标 Python 解释器路径（信息性） |
| `python_config` | `-Dpymz-python-config` | `python-config` 脚本路径 |
| `python_version` | `-Dpymz-python-version` | 目标 Python 版本字符串（如 `"2.7"`） |
| `python_includes` | `-Dpymz-python-includes` | 原始 include 标志 |
| `python_ldflags` | `-Dpymz-python-ldflags` | 原始链接器标志 |
| `python_libs` | `-Dpymz-python-libs` | 原始库标志 |
| `python_ext_suffix` | `-Dpymz-python-ext-suffix` | 扩展后缀（如 `".cpython-312-x86_64-linux-gnu.so"`） |

当 `python_includes` / `python_ldflags` / `python_ext_suffix` / `python_version` 同时提供时，
构建可以完全跳过宿主 `python-config` 发现，适合 CI 交叉编译场景。

## CLI 参考：`pymz-tool`

推荐把构建配置和矩阵写到 `pymz.json`，打包元数据写到 `pyproject.toml`，然后直接调用：

```bash
# 常用命令
pymz-tool build          # 为当前 Python 构建单个 wheel
pymz-tool matrix         # 按 pymz.json 中的 matrix 一键批量构建
pymz-tool develop        # 开发模式：原地构建并复制到 Python 包目录
pymz-tool config         # 读取并打印 pymz.json 配置摘要
```

CLI 参数会覆盖 `pymz.json` 中的同名配置，适合临时调试或无配置文件场景：

```bash
# 一次性指定所有信息
pymz-tool build --module _foo --distribution foo --version 0.1.0 \
    --package-dir python --release -o dist

# 矩阵构建
pymz-tool matrix --module _foo --distribution foo --version 0.1.0 \
    --python-versions 3.9,3.10,3.11,3.12 \
    --runtimes cpython3 \
    --targets x86_64-linux-gnu,aarch64-linux-gnu \
    --platform-tags manylinux_2_28_x86_64,manylinux_2_28_aarch64 \
    --release -o dist
```

### 常用参数

`--module`、`--distribution`、`--package-dir`、`--version`、
`--release`、`--zig-target`、`--platform-tag`、`--platform-tags`、`--targets`、
`--runtimes`、`--python-versions`、`-o/--out`。

使用 `example-multi` 或其他包含交叉目标的 Zig step 时必须显式传入
目标的 `--platform-tag`。`--python-versions` 仅对 `matrix` 必填（除非使用 `pymz.json` 矩阵）。
`--pymz-backend-source` 支持以 `;` 分隔多个候选后端入口。

### Python 配置参数

通过 `-Dpymz-python-*` 构建选项传入，主要用于 CI 或交叉编译：

| 选项 | 说明 |
|------|------|
| `-Dpymz-python-config` | `python-config` 脚本路径 |
| `-Dpymz-python-version` | 目标版本（如 `3.12`） |
| `-Dpymz-python-includes` | 原始 include 标志 |
| `-Dpymz-python-ldflags` | 原始链接器标志 |
| `-Dpymz-python-libs` | 原始库标志 |
| `-Dpymz-python-ext-suffix` | 扩展后缀 |
| `-Dpymz-windows-import-lib` | Windows 交叉编译的 Python import library |

这些参数也支持同名环境变量回退（`PYMZ_PYTHON_INCLUDES` 等），
优先级为 `-D` 构建选项 > 环境变量 > `python-config` 发现。

`PYMZ_ZIG` 环境变量仍可用于指定 `zig` 可执行文件路径。

运行 `pymz-tool --help` 查看完整列表。

### 平台标签与 manylinux / musl

`pymz-tool` 默认通过目标 Python 的 `packaging.tags` 推导 wheel 平台标签，
因此 Linux glibc 环境会得到 `manylinux_2_NN_*`，Alpine / musl 环境会得到
`musllinux_1_N_*`。也可以用 `--platform-tag manylinux_2_28_x86_64` 显式覆盖。

交叉构建时不能让宿主 Python 冒充目标 SDK。可分别提供目标解释器的配置值
（`-Dpymz-python-includes` 等）；Windows 目标还应提供 `-Dpymz-windows-import-lib`。
缺失时构建失败或明确报告无法链接，而不会生成错误标签的 wheel。

> **跨 OS 限制**：`shouldSkipCrossTarget` 默认跳过非宿主 OS 的目标（例如在 macOS
> 上无法直接交叉编译 Linux wheel），因为 `python-config` 只报告宿主工具链。完整的
> 跨 OS 矩阵需要为每个目标 OS 提供对应的 Python 工具链（通过 `-Dpymz-python-*`
> 选项或 `PYMZ_PYTHON_*` 环境变量注入），而非开箱即用。同 OS 内的跨架构（如
> x86_64-linux -> aarch64-linux）在提供目标 Python 工具链后可正常工作。

## 公共 API

| 名称 | 说明 |
| --- | --- |
| `pymz.py.decl.module(name, members, exc, doc)` | 声明 Python 模块。 |
| `pymz.py.decl.function(fn, .{ .doc, .signature })` | 暴露 Zig `fn` 为 Python 函数。 |
| `pymz.py.decl.kwFunction(fn, .{ .doc, .signature })` | 同上，支持关键字参数。 |
| `pymz.py.decl.positionalFunction(fn, opts)` | 仅按位置参数解析。 |
| `pymz.py.decl.varargsFunction(fn, opts)` | 接收 `*args` 变长参数。 |
| `pymz.py.decl.class(T, doc)` | 把 Zig struct 暴露为 Python 类。 |
| `pymz.py.decl.classWithBase(name, T, base, doc)` | 暴露带 Python 基类的 Zig struct。 |
| `pymz.py.decl.exception(.value_error, "msg")` | 声明自定义异常。 |
| `pymz.py.value.Result(T)` | 返回类型，等价于 `!T`。 |
| `pymz.py.value.Object` | 不透明的 `PyObject *`。 |
| `pymz.py.value.none/boolean/integer/floating/string` | 构造 Python 对象。 |
| `pymz.py.value.unicode(s)` | 构造 Unicode 文本对象（Python 2 为 `unicode`，Python 3 为 `str`）。 |
| `pymz.py.value.bytes(s)` / `pymz.py.value.bytearray(s)` | 构造 `bytes` / `bytearray` 对象。 |
| `pymz.py.value.list(n)` / `pymz.py.value.dict()` / `pymz.py.value.tuple(n)` | 构造容器。 |
| `pymz.py.value.set(items)` / `pymz.py.value.frozenset(items)` | 构造集合对象（需后端 `set_model` 能力）。 |
| `pymz.py.value.slice(start, stop, step)` | 构造切片对象（需后端 `slice_model` 能力）。 |

### 运行时后端

`pymz-tool/core` 通过 `-Dpymz-runtime=<name>` 选择内置后端能力档位，默认后端入口
是 `pymz/src/backend.zig`。如果要接入其他后端实现，可用
`-Dpymz-backend-source=<path>` 替换入口模块：

自定义 backend source 必须导出 `BackendSpec`、`Capabilities`、
`backendSpec()` 和 `Backend()`；构建系统提供 `@import("pymz_contract")`，
应使用其中的契约定义。公共层会强制使用 pymz 自身的契约校验。

| 后端 | 说明 |
| --- | --- |
| `cpython2` | CPython 2.x API；需要使用 Python 2 对应的 `python-config` 构建。 |
| `cpython3` | CPython 3.x 完整 API（默认）。 |
| `cpython3-limited` | CPython 3 稳定 ABI（abi3），目标 abi3 3.10+，适合跨 3.x 的轻量模块；当前不提供 class model。 |
| custom backend | **路线图，非已落地能力。** 需平行实现一套 runtime 对象布局和 GC 语义。 |

后端 capability 是硬约束：未实现的能力会在编译期拒绝，而不是运行时返回占位值。详见
[`pymz/src/contract.zig`](pymz/src/contract.zig) 和 [`pymz/src/py.zig`](pymz/src/py.zig)。

## ROADMAP

下列为已识别的改进方向与已知限制，按优先级排列。

- **现代 CPython API 采纳**：`versionAtLeast` 已实现并用于 `PyModule_AddObjectRef`
  （3.10+）。PEP 489 multi-phase 模块初始化已落地（`PyModuleDef_Init` +
  `m_slots` + `Py_mod_exec`），默认用于所有 Python 3 构建。3.12 的 `PyType_FromMetaclass`
  C 包装与版本门控已就位。PEP 703 free-threading 感知通过 `Py_IncRef` /
  `Py_DecRef` 稳定 ABI 函数原生兼容。
- **m_size multi-phase 兼容性**：已修复。`m_size` 从 `-1` 改为 `0`，兼容 CPython 3.12+
  的 multi-phase 初始化约束。
- **多后端落地验证**：`-Dpymz-backend-source` 注入槽位与 `Capabilities`/`validateBackend`
  契约层已就绪，但仅 CPython 一个实现。接入 PyPy/GraalPy 需平行实现一套 runtime。
- **跨 OS 一键构建**：`shouldSkipCrossTarget` 默认跳过非宿主 OS 的目标，因为
  `python-config` 只报宿主工具链。完整的跨 OS 矩阵需要通过 `PYMZ_PYTHON_*` 环境变量
  或 `-Dpymz-python-*` 选项注入目标 Python 工具链（已支持），而非开箱即用。

## 许可证

MIT。
