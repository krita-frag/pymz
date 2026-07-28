# pymz

> 用 Zig 写 Python 扩展：编译期反射自动生成绑定胶水代码，默认后端面向
> CPython 2.7 ~ 3.14，直接产出 wheel。同一份 Zig 源码对多个 Python 版本、
> 平台和 CPython 后端一键矩阵构建。

pymz 采用 **Zig** 构建绑定核心，通过编译期反射生成 CPython C API 胶水；
**pymz-tool**（纯 Python + 可复用 Zig 构建核心）负责 PEP 517 构建后端、CLI、
运行时加载器与 setuptools 集成。一套 Zig 源码兼容多版本（CPython 2.x/3.x）、
多平台（Linux/macOS/Windows/musl），自动生成符合 PEP 425 的 wheel 平台标签。

## 架构

三层（绑定核心 / 构建工具 / 用户扩展）+ 后端契约（Backend Contract）扩展层。

| 层级 | 位置 | 职责 | 边界约束 |
|------|------|------|----------|
| **绑定核心** | `pymz/src/` | 公共 API（`py.value`/`py.decl`）、后端契约（`contract.zig`）、CPython 运行时适配、内存/引用计数约定 | 不依赖任何构建工具概念；经 `pymz_backend` 模块间接访问运行时 |
| **构建工具** | `pymz-tool/` | `src/`（可复用 Zig 构建核心）、`python/`（PEP 517 后端、CLI、loader、setuptools 集成） | 纯 Python + Zig 构建脚本；不包含运行时绑定逻辑 |
| **参考示例** | `examples/jsonz/` | 完整端到端示例（`build.zig` + `pymz.json` + `pyproject.toml` + 测试） | 验证核心与工具链的试金石 |
| **用户扩展** | 仓库外 | 业务模块、自定义后端、DSL 变体 | 由用户自行实现 |

**核心原则**：一套代码兼容多版本、多平台。新功能引入前必须能回答"为什么放这一层"。
- 判定：能用现有原语组合实现 -> 不新增；只对部分用户有用 -> 用户扩展层。
- 绕过路径：用户可直接基于 `pymz.py`（公共 API）写自己的封装，构建侧可经 `-Dpymz-backend-source` 替换后端。

### 后端契约（Backend Contract）

所有运行时（cpython2 / cpython3 / cpython3-limited / custom）统一建模为 **RuntimeId** + **Capabilities**（能力声明）+ **BackendSpec**（后端元数据）+ **Backend()**（后端实现）。

- [contract.zig](file:///Users/a1-6/Documents/projects/pymz/pymz/src/contract.zig) 是后端无关的单一真相源（`RuntimeId` / `RuntimeInfo` / `runtimeInfo` / `Capabilities` / `validateBackend`），只依赖 `std`。
- `pymz_backend` 模块（默认入口 [backend.zig](file:///Users/a1-6/Documents/projects/pymz/pymz/src/backend.zig)）导出 `backendSpec()` 与 `Backend()`；`-Dpymz-backend-source` 可替换入口接入自定义后端。
- **capability 是硬约束**：未实现的能力在编译期拒绝（`@compileError`），而非运行时返回占位值。
- **"一套语法，多个后端"**：公共 API 经 `py.value` / `py.decl` 间接访问后端；**禁止直接 `@import("runtime/cpython.zig")` 绕过后端抽象**。
- `pymz_contract` 匿名模块间接引用保证 `contract.zig` 只被一个 module 拥有，使 `pymz` 与 `pymz_backend` 可在同一编译中共存。

### 公共 API

| 名称 | 说明 |
| --- | --- |
| `pymz.py.decl.module(name, members, exc, doc)` | 声明 Python 模块。 |
| `pymz.py.decl.function(fn, .{ .doc, .signature })` | 暴露 Zig `fn` 为 Python 函数。 |
| `pymz.py.decl.kwFunction` / `positionalFunction` / `varargsFunction` | 关键字 / 仅位置 / 变长参数函数。 |
| `pymz.py.decl.class(T, doc)` / `classWithBase(name, T, base, doc)` | 把 Zig struct 暴露为 Python 类。 |
| `pymz.py.decl.exception(.value_error, "msg")` | 声明自定义异常。 |
| `pymz.py.value.Result(T)` | 返回类型，等价于 `Error!T`。 |
| `pymz.py.value.Object` | 不透明 `PyObject *`。 |
| `pymz.py.value.none/boolean/integer/floating/string` | 构造 Python 对象。 |
| `pymz.py.value.list(n)` / `dict()` | 构造容器。 |

## 内存与引用计数约定

pymz 默认使用 `std.heap.c_allocator`，使 Zig 侧分配可被 Python 释放、反之亦然（见 [mem.zig](file:///Users/a1-6/Documents/projects/pymz/pymz/src/mem.zig)）：

- `pymz` helper 返回的 `*Object` 为**新引用**，调用方负责 `.decref()` 或转交 Python。
- 容器借用的 `*Object` 为**借用引用**，勿 `decref()` 除非已显式增引用计数。
- 从 `str`/`bytes` 提取的 `[]const u8` 为**借用缓冲**，对象释放后失效；需长期持有则用配置分配器拷贝。
- 持有 Python 引用的 Zig struct 字段须实现 `__del__` 或 GC traversal 释放。

## 技术栈

- **Zig**：`0.16.0`
- **Python**：2.7 / 3.8+（构建工具与 loader 要求 3.8+；setuptools 集成兼容 2.7+）
- **setuptools** ≥ 61；可选 direnv + Nix Flake 实现 100% 可复现环境

## 常用命令

```bash
# 环境就绪（direnv + Nix，推荐）
cd pymz && direnv allow

# Zig 单元测试
cd pymz-tool && zig build test --summary all   # 构建工具核心
cd pymz && zig build test --summary all        # 绑定核心 + 契约测试
zig build test --summary all                   # 工作区根（包检查 + 单元测试 + 示例构建）

# 构建示例 wheel
cd examples/jsonz
PYMZ_PYTHON=$(which python3) pymz-tool build
python -m pip install --force-reinstall --no-deps dist/*.whl
python -c "import jsonz; print(jsonz.validate_json('[1, 2, 3]'))"  # => True
python -m pytest tests/ -v

# 端到端试金石（支持 -v / --loader-only / -O ReleaseFast / -p python3.14）
cd examples/jsonz && ./test.sh

# 指定 Python 版本（Nix）
nix develop .#py27 --command ./test.sh
nix develop .#py314 --command bash -c 'cd examples/jsonz && ./test.sh'

# PEP 517 后端
cd examples/jsonz
python -m build --wheel --no-isolation
python -m build --sdist --no-isolation

# 矩阵构建
pymz-tool matrix           # 按 pymz.json 的 matrix 批量构建
pymz-tool config           # 打印 pymz.json 配置摘要
pymz-tool develop          # 开发模式：原地构建并复制到包目录
```

## 工作准则

1. **编码前先思考**：显式声明假设；不确定时主动询问；歧义时列出所有解释，不要默默选一种；存在更简单方案时主动提出。
2. **简洁优先**：不实现超出需求的内容；若 200 行能精简为 50 行，重写。
3. **精确变更**：不"顺手改进"相邻代码；匹配既有风格；仅删除因你的改动而失效的 import / 变量 / 函数；每一行变更都必须能直接追溯到用户请求。
4. **目标驱动**：用可验证目标替代模糊指令——"修复 Bug" -> 编写复现测试，修复，验证测试通过。
5. **生产代码禁止桩函数与 Mock**：不允许桩函数、占位实现、模拟数据、`pass` 或 `NotImplementedError`，不吞掉错误。`pymz/src/` 与 `pymz-tool/` 中的每个函数都必须在生产环境中正确工作。

## 代码约定

### 通用
- **注释原则**：注释应说明"当前实现是什么"以及"为何如此设计"，避免描述历史变更。历史信息对读者理解当前代码无帮助，反而会分散注意力。**禁止在注释中记录变更历史、个人备忘或任何与当前代码逻辑无关的内容**；版本控制工具已承担历史追溯职责，注释只服务于代码可读性。允许使用 `TODO`、`FIXME`、`HACK` 等标记圈出已知但尚未解决的功能缺口、缺陷或临时方案，此类标记应简洁说明问题本质与预期解决方向，例如 `TODO: cpython3-limited 暂不支持 class model，需补齐稳定 ABI 类型创建路径`。

### Zig
- 遵循 `zig fmt`，不抑制编译期检查。
- 错误处理：使用 `Error!T`（即 `pymz.py.value.Result(T)`）传播错误。`Error` 枚举经 [errors.zig](file:///Users/a1-6/Documents/projects/pymz/pymz/src/runtime/cpython/errors.zig) 的 `mapError` 映射到对应 Python 异常；`error.PyError` 表示"Python 异常已设置"，调用方无需再手动设置。
- **库代码避免 `@panic` / `catch unreachable` / `orelse unreachable`**：用错误联合传播失败。唯一例外是真正的编程错误守卫（如 [mem.zig](file:///Users/a1-6/Documents/projects/pymz/pymz/src/mem.zig) `setAllocator` 的"至多调用一次"检查），且须在文档注释中说明。
- **禁止 `_ = may_fail()` 静默丢弃错误**：必须显式处理 `Result`/错误联合，通过 `try`/`catch` 传播、记录或 `if` 处理；确实无需处理时需加注释说明原因。
- 内存分配走 `pymz.mem.allocator`（默认 `c_allocator`），不要直接用其他分配器；严格遵守 [mem.zig](file:///Users/a1-6/Documents/projects/pymz/pymz/src/mem.zig) 的引用计数约定。
- **禁止绕过后端抽象**：公共 API 经 `py.value` / `py.decl`，后端经 `pymz_backend`，契约经 `pymz_contract`；不要直接 `@import("runtime/cpython.zig")`。
- 顶层文档用 `//!`，声明文档用 `///`。
- 单元测试放在同文件 `test "..."` 块中；契约测试在 [pymz/tests/](file:///Users/a1-6/Documents/projects/pymz/pymz/tests)。

### Python
- **Python 2.7 是一等公民**：所有 `pymz-tool` 模块顶部使用 `from __future__ import absolute_import`；类型标注用**类型注释**（`# type: (str) -> dict`）而非 PEP 526 注解，以便 Python 2 解释器解析。`_compat.py` 提供 `typing.Any` shim。
- 私有实现使用 `_` 前缀。
- 未经用户明确要求不修改公共 API。
- 避免延迟导入，除非为打破循环依赖。
- 异常层级：`PymzError`（基类）-> `PymzConfigError` / `PymzBuildError` / `PymzManifestError`（见 [errors.py](file:///Users/a1-6/Documents/projects/pymz/pymz-tool/python/pymz_tool/errors.py)），使调用方无需裸 `except Exception` 即可区分 pymz 失败。
- **禁止裸 `except Exception` 吞错误**：必须捕获具体异常类型或向上传播。
- 资源对象（文件句柄、子进程）须实现 `__enter__`/`__exit__` 上下文管理器或使用 `try/finally` 确保释放。
- 模块用 `__all__` 显式声明导出。

## 测试

- 每次改动后运行受影响测试：
  - Zig：`cd pymz-tool && zig build test --summary all`、`cd pymz && zig build test --summary all`
  - Python：`python -m pytest examples/jsonz/tests/ pymz-tool/tests/ -v`
  - 端到端：`cd examples/jsonz && ./test.sh`
- 测试必须确定性；外部依赖需 mock。
- `examples/jsonz` 是核心与工具链的试金石——改动绑定核心或构建工具后必须让它通过。
- CI 矩阵：Ubuntu/macOS × Python 3.10–3.14，Windows 经 MSYS2 UCRT64，Python 2.7 由 `python2-regression`（setup.py 兼容性）与 `nix-python2-extension`（Nix CPython 2.7 扩展集成）两个作业覆盖。
