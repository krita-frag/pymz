//! pymz-tool 核心模块的测试聚合器。
//!
//! `cross.zig` 和 `python_config.zig` 拥有在 `zig build test` 下运行的编译期安全测试块。
//! CLI/wheel/config 功能由纯 Python 实现，通过 `tests/` pytest 套件测试。

const cross = @import("cross.zig");
const python_config = @import("python_config.zig");

comptime {
    _ = cross;
    _ = python_config;
}
