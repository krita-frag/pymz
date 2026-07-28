# Contributing to pymz

感谢你对 `pymz` 的兴趣！这份指南说明如何搭建本地开发环境、提交代码
以及参与发布流程。请在开始前阅读 [Code of Conduct](#code-of-conduct)
和 [README](README.md) 中的前置依赖说明。

## 1. 本地开发环境

| 工具 | 版本 | 备注 |
| --- | --- | --- |
| [Zig](https://ziglang.org) | `0.16.0` | 建议用 `zigup` 管理。 |
| Python | 3.8+ | 用于 PEP 517、loader 和端到端测试。 |
| `setuptools` | ≥ 61 | `pymz-tool` Python 集成包的构建依赖。 |
| `pytest` | ≥ 6 | 跑 Python 测试。 |

```bash
git clone https://github.com/pymz/pymz.git
cd pymz

# 安装 pymz-tool（纯 Python 包，无需构建 Zig 二进制）
python -m pip install -e pymz-tool pytest
```

## 2. 项目布局速览

```
pymz/                 # Zig 绑定核心、后端契约和公共 API 包
pymz-tool/            # 纯 Python PEP 517 + CLI + loader + setuptools 集成，以及可复用的 Zig 构建核心
pymz-tool/src/         # 可复用的 Zig 构建核心
pymz-tool/python/     # PEP 517、loader 和 setuptools 集成
examples/jsonz/       # 完整参考示例
```

请阅读 [README 的项目理念章节](README.md#项目理念) 了解 pymz 的
整体设计目标与多版本、多平台策略。

## 3. 开发工作流

### 3.1 修改 Zig 核心、后端契约或公共 API

1. 编辑 `pymz/src/` 下的文件。
2. 用 `examples/jsonz` 作为试金石：

   ```bash
   cd examples/jsonz
   # pymz-tool 自动从 pyproject.toml [tool.pymz] 读取 module/distribution/version/
   # package_dir 等配置。
   pymz-tool build --release
   pip install --force-reinstall --no-deps dist/*.whl
   python -m pytest tests/ -v
   ```

3. 如果新增了可独立测试的纯函数，请加 `test "..."` 块到对应文件
   末尾，并通过 `cd pymz-tool && zig build test` 跑一遍。

### 3.2 修改 `pymz-tool`

1. 编辑 `pymz-tool/src/` 下的文件。
2. 跑 Zig 单元测试：

   ```bash
   cd pymz-tool
   zig build test --summary all
   ```

3. 重新构建工具并跑端到端 wheel 流程（同上节步骤 2）。

### 3.3 修改 `pymz-tool` Python 集成层

1. 编辑 `pymz-tool/python/pymz_tool/setuptools.py`、`backend.py` 或 `loader.py`。
   Python 2 兼容逻辑与 Python 3 共享 `pymz-tool/python/pymz_tool/setuptools.py`。
2. 跑 Python 单元测试：

   ```bash
   python -m pytest examples/jsonz/tests/ -v
   ```

3. 如果改了 `ZigPackageSpec` 的字段或行为，请同步更新
   `examples/jsonz/pyproject.toml` 和 `README.md` 中的示例。

## 4. 提交规范

- **Commit message**：使用祈使句，首行不超过 72 字符。示例：
  `wheel: normalise platform tag separators to underscore`
- **Pull request**：标题同 commit message 风格。描述里说明：

  - 动机（为什么改）
  - 改动（做了什么）
  - 测试（怎么验证的，附本地命令输出）
  - Breaking changes（如果有）

- **不要在 PR 里混入无关的格式化或重构**。每个 PR 只做一件事。

## 5. 测试要求

任何代码改动都必须让下列所有检查通过：

```bash
# Zig 单元测试（pymz-tool）
cd pymz-tool && zig build test --summary all

# Zig 单元测试（pymz 核心库）
cd pymz && zig build test --summary all

# Python 单元测试
python -m pytest examples/jsonz/tests/ -v

# 端到端 wheel 测试
cd examples/jsonz
pymz-tool build --release
pip install --force-reinstall --no-deps dist/*.whl
python -m pytest tests/ -v

CI 在 Ubuntu / macOS × Python 3.10 – 3.14 上运行同样的端到端检查，
并通过 MSYS2 UCRT64 覆盖 Windows。Python 2.7 由两个独立作业覆盖：
`python2-regression`（setup.py 兼容性与 helper 测试）和
`nix-python2-extension`（Nix CPython 2.7 扩展集成）。

## 6. 发布流程

1. 更新 [`CHANGELOG.md`](CHANGELOG.md) 的 `[Unreleased]` 章节，
   把已合并的改动按 `Added` / `Changed` / `Fixed` 分类整理。
2. 把 `[Unreleased]` 改成新版本号 + 日期，并在底部新增空的
   `[Unreleased]` 章节。
3. 在 `pymz-tool/pyproject.toml` 和 `pymz-tool/build.zig.zon`（如有）里更新版本号。
4. 创建 annotated tag：`git tag -a v0.x.0 -m "Release 0.x.0"`。
5. 推送 tag，CI 会自动构建并上传 wheel 到 GitHub Release。

## 7. Code of Conduct

- 保持友善和耐心。对新手和经验丰富的贡献者一视同仁。
- 讨论聚焦于代码和技术决策，避免人身攻击。
- 不同意见优先以代码、文档、测试为依据，而非权威。
- 任何形式的骚扰、歧视或侮辱性言论零容忍。

违反者会被维护者移出仓库。

## 8. 联系方式

- GitHub Issues：用于 bug 报告和功能请求。
- GitHub Discussions：用于设计讨论和问答。
- 不要私下联系维护者讨论 PR；所有决策应在 PR 评论区公开进行。
