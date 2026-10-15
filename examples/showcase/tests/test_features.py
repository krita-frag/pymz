from __future__ import absolute_import, print_function

import sys

import pytest

import showcase


# ============================================================================
# ProtocolDemo - context manager + buffer protocol.
# ============================================================================

def test_protocol_demo_context_manager():
    with showcase.ProtocolDemo("hello") as demo:
        assert isinstance(demo, showcase.ProtocolDemo)


@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="memoryview on custom buffer objects is not tested on Python 2",
)
def test_protocol_demo_buffer_protocol():
    demo = showcase.ProtocolDemo("world")
    view = memoryview(demo)
    try:
        assert bytes(view) == b"world"
    finally:
        view.release()


# ============================================================================
# MatrixBuffer - buffer protocol with shape/strides.
# ============================================================================

@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="multi-dimensional memoryview is not tested on Python 2",
)
def test_matrix_buffer_shape_strides():
    matrix = showcase.MatrixBuffer()
    view = memoryview(matrix)
    try:
        assert view.shape == (2, 2)
        assert view.format == "B"
        assert view.readonly
        assert view.tolist() == [[1, 2], [3, 4]]
    finally:
        view.release()


# ============================================================================
# BaseCounter / DerivedCounter - inheritance.
# ============================================================================

def test_base_counter_increment():
    counter = showcase.BaseCounter()
    assert counter.increment() == 1
    assert counter.increment() == 2
    assert counter.increment() == 3


def test_derived_counter_increment():
    counter = showcase.DerivedCounter(5)
    assert counter.increment() == 5
    assert counter.increment() == 10


def test_derived_counter_has_increment_from_base():
    # DerivedCounter overrides increment() but inherits the method signature
    # from BaseCounter. Verify both work as expected.
    base = showcase.BaseCounter()
    assert base.increment() == 1
    assert base.increment() == 2

    derived = showcase.DerivedCounter(5)
    assert derived.increment() == 5
    assert derived.increment() == 10


def test_python_subclass_of_base_counter():
    class MyCounter(showcase.BaseCounter):
        pass

    counter = MyCounter()
    assert counter.increment() == 1
    assert counter.increment() == 2


# ============================================================================
# CallableOpt - __call__ with optional argument.
# ============================================================================

def test_callable_opt_no_args_returns_base():
    obj = showcase.CallableOpt(7)
    assert obj() == 7


def test_callable_opt_with_factor_returns_product():
    obj = showcase.CallableOpt(7)
    assert obj(3) == 21


def test_callable_opt_with_none_returns_base():
    obj = showcase.CallableOpt(5)
    assert obj(None) == 5


# ============================================================================
# IntVec - container protocols + rich comparison + iterator.
# ============================================================================

def _make_vec(*values):
    # type: (*int) -> showcase.IntVec
    vec = showcase.IntVec()
    for v in values:
        vec.push(v)
    return vec


def test_intvec_push_pop_clear():
    vec = showcase.IntVec()
    assert len(vec) == 0
    vec.push(1)
    vec.push(2)
    vec.push(3)
    assert len(vec) == 3
    assert vec.pop() == 3
    assert vec.pop() == 2
    assert len(vec) == 1
    vec.clear()
    assert len(vec) == 0


def test_intvec_pop_empty_raises():
    vec = showcase.IntVec()
    with pytest.raises(showcase.IntVecError):
        vec.pop()


def test_intvec_getitem_positive():
    vec = _make_vec(10, 20, 30)
    assert vec[0] == 10
    assert vec[1] == 20
    assert vec[2] == 30


def test_intvec_getitem_negative():
    vec = _make_vec(10, 20, 30)
    assert vec[-1] == 30
    assert vec[-2] == 20
    assert vec[-3] == 10


def test_intvec_getitem_out_of_bounds_raises():
    vec = _make_vec(1, 2)
    with pytest.raises(showcase.IntVecError):
        _ = vec[5]
    with pytest.raises(showcase.IntVecError):
        _ = vec[-10]


def test_intvec_setitem():
    vec = _make_vec(1, 2, 3)
    vec[0] = 100
    vec[1] = 200
    vec[-1] = 300
    assert vec[0] == 100
    assert vec[1] == 200
    assert vec[2] == 300


def test_intvec_setitem_out_of_bounds_raises():
    vec = _make_vec(1)
    with pytest.raises(showcase.IntVecError):
        vec[10] = 99


def test_intvec_delitem():
    vec = _make_vec(1, 2, 3, 4, 5)
    del vec[0]
    assert len(vec) == 4
    assert vec[0] == 2
    del vec[-1]
    assert len(vec) == 3
    assert vec[2] == 4


def test_intvec_delitem_negative():
    vec = _make_vec(10, 20, 30)
    del vec[-1]
    assert len(vec) == 2
    assert vec[0] == 10
    assert vec[1] == 20


def test_intvec_delitem_out_of_bounds_raises():
    vec = _make_vec(1, 2, 3)
    with pytest.raises(showcase.IntVecError):
        del vec[10]
    with pytest.raises(showcase.IntVecError):
        del vec[-10]
    assert len(vec) == 3


def test_intvec_contains():
    vec = _make_vec(1, 2, 3)
    assert 1 in vec
    assert 2 in vec
    assert 3 in vec
    assert 99 not in vec
    assert 0 not in vec


def test_intvec_iter():
    vec = _make_vec(1, 2, 3)
    assert list(vec) == [1, 2, 3]


def test_intvec_iter_resets():
    vec = _make_vec(1, 2)
    assert list(vec) == [1, 2]
    assert list(vec) == [1, 2]


def test_intvec_eq():
    vec = _make_vec(1, 2, 3)
    assert vec == [1, 2, 3]
    assert vec == (1, 2, 3)


def test_intvec_eq_different_content():
    vec = _make_vec(1, 2, 3)
    assert not (vec == [1, 2, 4])
    assert not (vec == [1, 2])


def test_intvec_ne():
    vec = _make_vec(1, 2, 3)
    assert vec != [1, 2, 4]
    assert vec != [1, 2]
    assert not (vec != [1, 2, 3])


def test_intvec_lt():
    vec = _make_vec(1, 2, 3)
    assert vec < [1, 2, 4]
    assert vec < [1, 2, 3, 4]
    assert not (vec < [1, 2, 3])
    assert not (vec < [1, 2])


def test_intvec_le():
    vec = _make_vec(1, 2, 3)
    assert vec <= [1, 2, 3]
    assert vec <= [1, 2, 4]
    assert not (vec <= [1, 2, 2])
    assert not (vec <= [1, 2])


def test_intvec_gt():
    vec = _make_vec(1, 2, 3)
    assert vec > [1, 2, 2]
    assert vec > [1, 2]
    assert not (vec > [1, 2, 3])
    assert not (vec > [1, 2, 4])


def test_intvec_ge():
    vec = _make_vec(1, 2, 3)
    assert vec >= [1, 2, 3]
    assert vec >= [1, 2, 2]
    assert vec >= [1, 2]
    assert not (vec >= [1, 2, 4])
    assert not (vec >= [1, 2, 3, 4])


def test_intvec_ge_element_larger_but_shorter():
    """元素在某位置更大但总长度更短时，>= 应返回 True。"""
    vec = _make_vec(1, 2, 5)
    assert vec >= [1, 2, 3, 4]  # 5 > 3, 尽管长度 3 < 4
    assert vec >= [1, 2, 5]
    assert not (vec >= [1, 2, 6, 1])  # 5 < 6


def test_intvec_str():
    assert str(_make_vec(1, 2, 3)) == "[1, 2, 3]"
    assert str(showcase.IntVec()) == "[]"


def test_intvec_repr():
    assert repr(_make_vec(1, 2, 3)) == "IntVec([1, 2, 3])"
    assert repr(showcase.IntVec()) == "IntVec([])"


def test_intvec_hash_consistent():
    vec1 = _make_vec(1, 2, 3)
    vec2 = _make_vec(1, 2, 3)
    assert vec1 == vec2
    assert hash(vec1) == hash(vec2)
    assert hash(vec1) == hash(vec1)
    assert isinstance(hash(vec1), int)


def test_intvec_hash_differs_for_different_content():
    vec1 = _make_vec(1, 2, 3)
    vec2 = _make_vec(3, 2, 1)
    assert hash(vec1) != hash(vec2)


def test_intvec_call_returns_length():
    vec = _make_vec(1, 2, 3)
    assert vec() == 3
    vec.push(4)
    assert vec() == 4
    vec.clear()
    assert vec() == 0


# ============================================================================
# sum_all - varargs function.
# ============================================================================

def test_sum_all_multiple_args():
    assert showcase.sum_all(1, 2, 3) == 6
    assert showcase.sum_all(10, 20, 30, 40) == 100


def test_sum_all_single_arg():
    assert showcase.sum_all(42) == 42


def test_sum_all_no_args():
    assert showcase.sum_all() == 0


def test_sum_all_negative_numbers():
    assert showcase.sum_all(-1, -2, -3) == -6
    assert showcase.sum_all(1, -2, 3) == 2


# ============================================================================
# make_containers - container construction with value constructors.
# ============================================================================

def test_make_containers_keys():
    result = showcase.make_containers()
    expected_keys = {
        "bytes", "bytearray", "tuple", "set",
        "frozenset", "unicode", "slice",
    }
    assert set(result.keys()) == expected_keys


def test_make_containers_bytes():
    val = showcase.make_containers()["bytes"]
    assert isinstance(val, bytes)
    assert val == b"hello"


def test_make_containers_bytearray():
    val = showcase.make_containers()["bytearray"]
    assert isinstance(val, bytearray)
    assert bytes(val) == b"world"


def test_make_containers_tuple():
    val = showcase.make_containers()["tuple"]
    assert isinstance(val, tuple)
    assert val == (1, 2, 3)


def test_make_containers_set():
    val = showcase.make_containers()["set"]
    assert isinstance(val, set)
    assert val == {1, 2}


def test_make_containers_frozenset():
    val = showcase.make_containers()["frozenset"]
    assert isinstance(val, frozenset)
    assert val == frozenset({10, 20})


def test_make_containers_unicode():
    val = showcase.make_containers()["unicode"]
    if sys.version_info[0] >= 3:
        assert isinstance(val, str)
    else:
        assert isinstance(val, unicode)  # noqa: F821 - Py2 builtin
    assert val == u"h\u00e9llo"


def test_make_containers_slice():
    val = showcase.make_containers()["slice"]
    assert isinstance(val, slice)
    assert val.start == 0
    assert val.stop == 10
    assert val.step == 2


# ============================================================================
# ShowcaseError - custom exception.
# ============================================================================

def test_showcase_error_is_runtime_error():
    assert issubclass(showcase.ShowcaseError, RuntimeError)


def test_showcase_error_can_be_raised_and_caught():
    with pytest.raises(showcase.ShowcaseError):
        raise showcase.ShowcaseError("test error")


def test_showcase_error_caught_as_runtime_error():
    with pytest.raises(RuntimeError):
        raise showcase.ShowcaseError("test error")


# ============================================================================
# Handle / Registry - py_class declarative cross-class conversion.
# ============================================================================

def test_py_class_cross_return_isinstance():
    reg = showcase.Registry()
    handle = reg.make(42)
    assert isinstance(handle, showcase.Handle)


def test_py_class_cross_return_type_identity():
    # 返回的实例类型必须与模块导出的类是同一类型对象（isinstance 恒真的根因：
    # module 注册与 convert.instantiate 使用同一个 py_class.name comptime 键）。
    reg = showcase.Registry()
    handle = reg.make(42)
    assert type(handle) is showcase.Handle


def test_py_class_cross_return_value():
    reg = showcase.Registry()
    assert reg.make(42).get_value() == 42
    assert reg.make(-1).get_value() == -1


def test_py_class_direct_construction():
    # 直接构造仍然走 __new__，与跨类返回物化（绕过 __new__ 直接拷贝载荷）共存。
    handle = showcase.Handle(7)
    assert handle.get_value() == 7


def test_py_class_extract_parameter():
    # 反向方向：参数为 HandleImpl，pymz 从 Handle 实例提取载荷后调用。
    reg = showcase.Registry()
    assert reg.add(showcase.Handle(10), showcase.Handle(32)) == 42
    assert reg.add(reg.make(1), reg.make(2)) == 3


def test_py_class_not_exposed_as_method():
    # py_class 的动机之一：`toPy` 若声明为普通方法会被方法表暴露，py_class 不会。
    handle = showcase.Registry().make(1)
    assert not hasattr(handle, "toPy")
    assert not hasattr(showcase.Handle, "toPy")
    assert not hasattr(showcase.Handle, "py_class")


def test_py_class_instance_is_readonly():
    handle = showcase.Handle(5)
    with pytest.raises(AttributeError):
        handle._value = 99
