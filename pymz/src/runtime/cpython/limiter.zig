//! CPython 运行时的构建期平台门控。
//!
//! `is_limited_api` 是*构建期选择*（pymz 是否配置为 CPython 稳定 ABI），
//! 而非 C 头文件属性。它通过 `pymz_options` 构建选项模块传递，使此文件保
//! 持轻量：既不导入 `python_c`（翻译后的 C 头文件），也不导入 `pymz_backend`
//! 模块树之外的任何文件。保持轻量使得声明式描述符和版本模块可以访问
//! `is_limited_api` / `isActiveForPlatform`，而无需跨模块文件导入——在
//! Zig 0.16 下，跨模块导入会导致"文件存在于两个模块中"的冲突。
//!
//! 公共 `pymz.platform` 命名空间（在 `pymz` 模块中）仍然为最终用户导出
//! `is_limited()` / `is_limited_api`；它通过后端模块从
//! `backendSpec().capabilities.stable_abi` 派生该值。此文件是运行时代码
//! *内部*使用的路径。

const options = @import("pymz_options");

/// 当所选运行时为 CPython 稳定 ABI（limited API）时为真。
/// 由构建选项驱动，因此该值在编译运行时的所有地方都是编译期常量，
/// 无需运行时后端或 C 头文件。
pub const is_limited_api: bool = options.is_limited_api;

/// 当具有给定 `limited` 过滤器的声明应在当前平台上激活时返回真。
///
/// `null` 表示"在所有平台上激活"；`true` 表示"仅限 limited ABI"；
/// `false` 表示"仅限完整 ABI"。这是所有声明式描述符（class、function、
/// constant、exception）使用的统一实现。
pub fn isActiveForPlatform(comptime limited: ?bool) bool {
    if (limited) |value| {
        return value == is_limited_api;
    }
    return true;
}