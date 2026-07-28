//! 测试聚合器入口点。
//!
//! 通过 `build.zig` 中配置的匿名导入来引入实际测试模块的轻量封装。
//! 这使 `src/` 内部与测试模块根目录隔离，从而 `src/` 内的相对导入仍能正常工作。

comptime {
    _ = @import("core_tests");
    _ = @import("backend_contract.zig");
}
