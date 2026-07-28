//! pymz 的内存分配与所有权约定。
//!
//! 默认情况下 pymz 使用 C 分配器，以便 Zig 侧的分配可被 Python 释放，
//! 反之亦然。测试可在创建 Python 对象之前通过 `setAllocator()` 覆盖此行为。
//!
//! pymz 中使用的所有权约定：
//!
//!   * `pymz` 辅助函数返回的 `*Object`（如 `pymz.string`、`pymz.integer`）
//!     为**新引用**。调用方拥有它，完成后必须调用 `.decref()`，或将其所有权
//!     交还给 Python。
//!
//!   * `Object.newref()` 返回的 `*Object` 是通过递增现有对象引用计数创建的
//!     **新引用**。
//!
//!   * 从容器的借用（如 `Object.sequenceGet`、`Dict.get`）得到的 `*Object`
//!     为**借用引用**。它仅在容器存活期间有效。除非已显式递增引用计数，
//!     否则不要对借用引用调用 `.decref()`。
//!
//!   * 通过 `fromPy` 从 Python `str`/`bytes` 提取的 `[]const u8` 为
//!     **借用缓冲**。它指向 Python 对象的内部存储，在该对象被释放后失效。
//!     如果数据需要比 Python 对象存活更久，使用配置的分配器拷贝。
//!
//!   * 通过 `fromPy` 从 Python `bytes`/`bytearray` 提取的 `[]u8` 为
//!     **拥有的拷贝**。调用方完成后必须使用 `pymz.mem.allocator.free` 释放。
//!
//!   * 持有 Python 引用的 Zig struct 字段必须保持这些对象存活（例如通过
//!     存储 `*Object` 并递增引用计数），并且必须实现 `__del__` 或 GC 遍历
//!     来释放它们。

const std = @import("std");

/// pymz 内部所有分配使用的分配器。
///
/// 默认为 `std.heap.c_allocator`，这对 CPython 扩展代码是必需的，因为
/// Zig 侧的分配可能被 Python 通过 libc 的 `free()` 释放，反之亦然。
///
/// 测试可在测试运行器开始时调用 `setAllocator()` 覆盖为调试分配器（如
/// `std.heap.GeneralPurposeAllocator`）。分配器必须在任何 Python 对象创建
/// 之前设置，之后不得更改。
pub var allocator: std.mem.Allocator = std.heap.c_allocator;

/// 在 `setAllocator` 被调用后设为 `true`。用于防止在分配开始后意外切换分配器。
var allocator_set: bool = false;

/// 覆盖全局分配器。仅在启动时（如测试运行器中）有意义，且在任何 pymz 对象
/// 分配之前调用。多次调用此函数是编程错误，在调试构建中会 panic。
pub fn setAllocator(alloc: std.mem.Allocator) void {
    if (allocator_set) {
        @panic("setAllocator must be called at most once, before any pymz allocations");
    }
    allocator = alloc;
    allocator_set = true;
}
