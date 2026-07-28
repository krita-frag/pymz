"""c_allocator 与 CPython 对象分配器交互安全性验证。

pymz 默认使用 ``std.heap.c_allocator``（即 libc 的 malloc/free）用于 Zig 侧
缓冲，而 CPython 对象经 pymz helper 创建时走 CPython 自己的对象分配器
（pymalloc / PyObject_Malloc）。此测试验证两条分配通路在大量交叉分配/释放
循环中不会互相破坏：

  - Zig 侧：``echo_bytes`` 在内部用 ``c_allocator.dupe`` 复制入参 bytes，
    返回的 ``[]u8`` 又由 ``marshal`` 经 ``c_allocator.free`` 释放。
  - Python 侧：``parse_json`` / ``dump_json`` 创建大量 dict/list/str/int
    对象，由 CPython 引用计数 + GC 回收。

如果两条通路混淆（例如 Python 试图 ``PyObject_Free`` 一个 libc malloc 指针，
或 Zig 试图 ``free`` 一个 pymalloc 指针），会在压力循环中崩溃或破坏堆。
"""
from __future__ import absolute_import, print_function

import gc
import sys

import pytest

import jsonz


# 小对象走 CPython pymalloc arena（<=512 字节），大对象走系统 malloc。
# 两个尺寸都覆盖，验证 pymz 的 c_allocator 不与任一通路冲突。
SMALL_BYTES = b"x" * 64
LARGE_BYTES = b"y" * 4096


def test_echo_bytes_repeated_small_allocations():
    """大量小尺寸 Zig 缓冲分配/释放，验证不与 pymalloc arena 冲突。"""
    for _ in range(2000):
        result = jsonz.echo_bytes(SMALL_BYTES)
        assert result == SMALL_BYTES
        del result
    gc.collect()


def test_echo_bytes_repeated_large_allocations():
    """大量大尺寸 Zig 缓冲分配/释放，验证不与系统 malloc 冲突。"""
    for _ in range(500):
        result = jsonz.echo_bytes(LARGE_BYTES)
        assert result == LARGE_BYTES
        del result
    gc.collect()


def test_parse_json_creates_many_python_objects():
    """parse_json 创建大量 Python 对象，触发 CPython GC 后再分配 Zig 缓冲。"""
    payload = '[1, 2, 3, {"a": "b", "c": [4, 5, 6]}, "hello"]'
    for _ in range(500):
        parsed = jsonz.parse_json(payload)
        assert parsed[3]["c"] == [4, 5, 6]
        del parsed
    gc.collect()
    # GC 后立即分配 Zig 缓冲，验证 pymalloc 释放的内存未被 libc 误用。
    assert jsonz.echo_bytes(b"after-gc") == b"after-gc"


def test_dump_json_after_heavy_python_allocation():
    """dump_json 大量分配 Python str/bytes 后再创建 Python 对象，验证无交叉。"""
    for _ in range(500):
        s = jsonz.dump_json({"k": [1, 2, 3], "v": "value"})
        assert '"k"' in s
        del s
    gc.collect()
    # 立即创建大量 Python 对象，验证 c_allocator 释放的内存未被 pymalloc 误用。
    objs = [jsonz.parse_json('{"x": 1}') for _ in range(100)]
    assert len(objs) == 100
    del objs
    gc.collect()


def test_interleaved_zig_and_python_allocations():
    """交叉分配：每次循环同时分配 Zig 缓冲和 Python 对象。"""
    for i in range(300):
        zig_buf = jsonz.echo_bytes(("iter-%d" % i).encode("ascii"))
        py_obj = jsonz.parse_json('{"i": %d}' % i)
        assert zig_buf == ("iter-%d" % i).encode("ascii")
        assert py_obj["i"] == i
        del zig_buf, py_obj
    gc.collect()


def test_jsonpath_lifecycle_exercises_class_allocator_paths():
    """JsonPath 的创建/销毁经 PyType_GenericNew + tp_dealloc，
    验证自定义类对象分配与 Zig c_allocator 共存无冲突。"""
    paths = []
    for _ in range(100):
        path = jsonz.JsonPath("a.b.c")
        paths.append(path)
    # 在 JsonPath 存活期间分配/释放 Zig 缓冲
    for _ in range(50):
        jsonz.echo_bytes(b" interleaved ")
    # 触发 JsonPath 析构（tp_dealloc 调用 __del__ -> ArrayList.deinit 走 c_allocator）
    del paths
    gc.collect()


@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="gc.collect() return count is unreliable on Python 2",
)
def test_gc_cycle_collection_after_zig_allocation():
    """在大量 Zig 缓冲分配后触发循环 GC，验证 GC 不破坏 Zig 持有的指针。"""
    # 先分配一些 Zig 缓冲并丢弃（验证 GC 不回收 c_allocator 的内存）
    for _ in range(100):
        jsonz.echo_bytes(b"gc-probe")
    # 触发完整 GC
    collected = gc.collect()
    # GC 后再分配，验证堆未被破坏
    assert jsonz.echo_bytes(b"post-gc") == b"post-gc"
    # collected 是非负整数（具体值取决于 GC 状态，不强制断言）
    assert collected >= 0
