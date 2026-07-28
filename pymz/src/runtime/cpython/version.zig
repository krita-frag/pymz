//! Python 版本检测辅助函数。
//!
//! `py_major`、`py_minor`、`py_hex`、`is_py3`、`is_py2` 和 `versionAtLeast`
//! 从 CPython C 头文件（`PY_MAJOR_VERSION` 等）派生，反映实际链接的解释器。
//!
//! `is_limited_api` 是*运行时选择*（pymz 是否配置为 CPython 稳定 ABI），
//! 而非 C 头文件属性。它从 `limiter.zig` 重新导出，后者读取构建期
//! `pymz_options.is_limited_api` 标志。通过 `limiter.zig`（同一模块树）而非
//! `../../platform.zig`（`pymz` 模块的文件）路由，避免了在 Zig 0.16 的
//! 单拥有者文件规则下会冲突的跨模块文件导入。

const std = @import("std");
const c = @import("python_c");
const limiter = @import("limiter.zig");

pub const py_major = c.PY_MAJOR_VERSION;
pub const py_minor = c.PY_MINOR_VERSION;
pub const py_hex = c.PY_VERSION_HEX;

pub const is_py3 = py_major >= 3;
pub const is_py2 = py_major == 2;

/// 当所选运行时为 CPython 稳定 ABI（limited API）时为真。
/// 从 `limiter.is_limited_api` 重新导出，后者读取构建选项。
pub const is_limited_api = limiter.is_limited_api;

/// PEP 489 多阶段模块初始化在所有 Python 3.x 上可用。
pub const has_pep489 = is_py3;

/// Python 3.12+：`PyType_FromMetaclass` 允许通过 PyType_Spec / PyType_Slot
/// API 路径创建具有自定义元类的类型。
pub const has_pytype_from_metaclass = is_py3 and versionAtLeast(3, 12);

pub inline fn versionAtLeast(comptime major: u32, comptime minor: u32) bool {
    const need = (major << 24) | (minor << 16);
    return py_hex >= need;
}