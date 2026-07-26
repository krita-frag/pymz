import inspect
import os
import sys

import pytest

import jsonz


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_parse_json_primitives():
    assert jsonz.parse_json("null") is None
    assert jsonz.parse_json("true") is True
    assert jsonz.parse_json("false") is False
    assert jsonz.parse_json("42") == 42
    assert jsonz.parse_json("3.14") == 3.14
    assert jsonz.parse_json('"hello"') == "hello"


def test_parse_json_nested():
    value = jsonz.parse_json('{"a": [1, 2.5, true, null], "b": "x"}')
    assert value == {"a": [1, 2.5, True, None], "b": "x"}


def test_dump_json_minified():
    result = jsonz.dump_json({"x": [1, 2], "y": None})
    assert result == '{"x":[1,2],"y":null}'


def test_dump_json_indent():
    result = jsonz.dump_json({"x": [1, 2]}, indent=2)
    assert '"x":' in result
    assert '\n' in result


def test_dump_json_invalid_type():
    with pytest.raises(jsonz.JsonError):
        jsonz.dump_json(object())


def test_dump_json_rejects_extra_positional_args():
    with pytest.raises(TypeError):
        jsonz.dump_json({"x": 1}, 2, 3)


def test_dump_json_rejects_unknown_keyword_args():
    with pytest.raises(TypeError):
        jsonz.dump_json({"x": 1}, foo=1)


def test_dump_json_rejects_duplicate_argument_values():
    with pytest.raises(TypeError):
        jsonz.dump_json({"x": 1}, obj={"y": 2})


def test_dump_json_escapes_control_characters():
    result = jsonz.dump_json("line\x00break\t")
    assert result == '"line\\u0000break\\t"'


def test_validate_json():
    assert jsonz.validate_json('{"a": 1}') is True
    assert jsonz.validate_json("not json") is False


def test_echo_bytes_roundtrip():
    data = b"hello\x00\xffworld"
    assert jsonz.echo_bytes(data) == data


def test_json_path_dict():
    path = jsonz.JsonPath("a.b")
    assert path.find({"a": {"b": 42}}) == 42


def test_json_path_list():
    path = jsonz.JsonPath("items.1.name")
    data = {"items": [{"name": "first"}, {"name": "second"}]}
    assert path.find(data) == "second"


def test_json_path_missing_key():
    path = jsonz.JsonPath("missing")
    with pytest.raises(jsonz.JsonError):
        path.find({})


def test_json_path_bad_index():
    path = jsonz.JsonPath("items.x")
    with pytest.raises(jsonz.JsonError):
        path.find({"items": []})


def test_json_path_readonly_property():
    path = jsonz.JsonPath("a.b.c")
    assert path.segment_count == 3


def test_json_path_repr():
    assert repr(jsonz.JsonPath("a.b")) == "JsonPath"


def test_json_error_attribute():
    assert issubclass(jsonz.JsonError, ValueError)


def test_module_version_constant():
    assert jsonz.__version__ == "1.0.0"


@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="inspect.signature is not available on Python 2",
)
def test_signature_for_json_path_method():
    assert str(inspect.signature(jsonz.JsonPath.find)) == "(self, root, /)"


def test_generated_pyi_contains_public_api_signatures():
    # .pyi 存根在 wheel/editable 安装后位于 jsonz 包目录中。
    stub_path = os.path.join(os.path.dirname(jsonz.__file__), "_jsonz.pyi")
    with open(stub_path, "r") as f:
        stub = f.read()

    assert "def parse_json(text: str, /) -> Any: ..." in stub
    assert "def dump_json(obj: Any, indent: int | None = None) -> str: ..." in stub
    assert "def validate_json(text: str, /) -> bool: ..." in stub
    assert "class JsonError(Exception):" in stub
    assert "class JsonPath:" in stub
    assert "def find(self, root: Any, /) -> Any: ..." in stub
    assert "class ProtocolDemo:" in stub
    assert "class MatrixBuffer:" in stub
    assert "class BaseCounter:" in stub
    assert "class DerivedCounter:" in stub


@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="memoryview on custom buffer objects is not tested on Python 2",
)
def test_protocol_demo_context_manager():
    with jsonz.ProtocolDemo("hello") as demo:
        assert isinstance(demo, jsonz.ProtocolDemo)


@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="memoryview on custom buffer objects is not tested on Python 2",
)
def test_protocol_demo_buffer_protocol():
    demo = jsonz.ProtocolDemo("world")
    view = memoryview(demo)
    try:
        assert bytes(view) == b"world"
    finally:
        view.release()


@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="multi-dimensional memoryview is not tested on Python 2",
)
def test_matrix_buffer_multi_dimensional():
    matrix = jsonz.MatrixBuffer()
    view = memoryview(matrix)
    try:
        assert view.shape == (2, 2)
        assert view.format == "B"
        assert view.readonly
        assert view.tolist() == [[1, 2], [3, 4]]
    finally:
        view.release()


def test_python_subclass_of_extension_class():
    class MyCounter(jsonz.BaseCounter):
        pass

    counter = MyCounter()
    assert counter.increment() == 1
    assert counter.increment() == 2


def test_extension_derived_class():
    counter = jsonz.DerivedCounter(5)
    assert counter.increment() == 5
    assert counter.increment() == 10


@pytest.mark.skipif(
    sys.version_info[0] < 3,
    reason="cyclic GC test uses gc module not exercised on Python 2",
)
def test_gc_cycle_collection():
    import gc

    before = jsonz.gc_node_dealloc_count()
    root = jsonz.GCNode(1)
    child = jsonz.GCNode(2)
    root.set_child(child)
    child.set_child(root)
    root_id = id(root)
    child_id = id(child)

    del root, child
    gc.collect()

    objs = gc.get_objects()
    assert not any(id(o) == root_id for o in objs)
    assert not any(id(o) == child_id for o in objs)
    assert jsonz.gc_node_dealloc_count() - before == 2
