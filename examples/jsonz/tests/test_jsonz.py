import jsonz
import inspect
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


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
    try:
        jsonz.dump_json(object())
    except jsonz.JsonError:
        pass
    else:
        raise AssertionError("expected JsonError")


def test_dump_json_rejects_extra_positional_args():
    with pytest.raises(TypeError):
        jsonz.dump_json({"x": 1}, 2, 3)


def test_dump_json_rejects_unknown_keyword_args():
    with pytest.raises(TypeError):
        jsonz.dump_json({"x": 1}, foo=1)


def test_dump_json_rejects_duplicate_argument_values():
    with pytest.raises(TypeError):
        jsonz.dump_json({"x": 1}, obj={"y": 2})


def test_validate_json():
    assert jsonz.validate_json('{"a": 1}') is True
    assert jsonz.validate_json("not json") is False


def test_json_path_dict():
    path = jsonz.JsonPath("a.b")
    assert path.find({"a": {"b": 42}}) == 42


def test_json_path_list():
    path = jsonz.JsonPath("items.1.name")
    data = {"items": [{"name": "first"}, {"name": "second"}]}
    assert path.find(data) == "second"


def test_json_path_missing_key():
    path = jsonz.JsonPath("missing")
    try:
        path.find({})
    except jsonz.JsonError:
        pass
    else:
        raise AssertionError("expected JsonError")


def test_json_path_bad_index():
    path = jsonz.JsonPath("items.x")
    try:
        path.find({"items": []})
    except jsonz.JsonError:
        pass
    else:
        raise AssertionError("expected JsonError")


def test_json_error_attribute():
    assert issubclass(jsonz.JsonError, ValueError)


def test_signature_for_json_path_method():
    assert str(inspect.signature(jsonz.JsonPath.find)) == "(self, root, /)"


def test_json_path_repr():
    assert repr(jsonz.JsonPath("a.b")) == "JsonPath"


def test_generated_pyi_contains_public_api_signatures():
    stub = (ROOT / "zig-out" / "lib" / "jsonz.pyi").read_text()

    assert "def parse_json(text: str, /) -> Any: ..." in stub
    assert "def dump_json(obj: Any, indent: int | None = None) -> str: ..." in stub
    assert "def validate_json(text: str, /) -> bool: ..." in stub
    assert "class JsonError(Exception):" in stub
    assert "def __init__(self, pattern: str, /) -> None: ..." in stub
    assert "def find(self, root: Any, /) -> Any: ..." in stub
