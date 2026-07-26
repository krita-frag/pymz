import sys

import pytest

from pymz_tool import ZigPackageSpec, python_version_string


def test_python_version_string_matches_runtime():
    assert python_version_string() == "%d.%d" % sys.version_info[:2]


@pytest.mark.skipif(ZigPackageSpec is None, reason="setuptools not installed")
def test_spec_build_command_is_stable(tmpdir):
    spec = ZigPackageSpec(str(tmpdir), "jsonz", "_jsonz")
    assert spec.extension_import_name == "jsonz._jsonz"
    assert spec.zig_build_command("3.12") == [
        "zig",
        "build",
        "example",
        "-Dpython-version=3.12",
    ]

if sys.version_info[0] >= 3:
    from pymz_tool.cli import _split_csv, _split_backend_sources, _build_parser
    from pymz_tool.matrix import build_matrix_from_cli

    def test_split_csv():
        assert _split_csv("a,b,c") == ["a", "b", "c"]
        assert _split_csv("a, b , c") == ["a", "b", "c"]
        assert _split_csv("single") == ["single"]
        assert _split_csv("") is None
        assert _split_csv(None) is None

    def test_split_backend_sources():
        assert _split_backend_sources(None) == [None]
        assert _split_backend_sources("") == [None]
        assert _split_backend_sources("/path/a") == ["/path/a"]
        assert _split_backend_sources("/path/a;/path/b") == ["/path/a", "/path/b"]
        assert _split_backend_sources("/path/a; /path/b ;") == ["/path/a", "/path/b"]

    def test_build_parser_accepts_build_flags():
        parser = _build_parser()
        opts = parser.parse_args([
            "build",
            "--module", "_foo",
            "--distribution", "foo",
            "--package-dir", "python",
            "--version", "0.1.0",
            "--release",
            "-o", "dist",
            "--runtime", "cpython3",
            "--platform-tag", "manylinux_2_28_x86_64",
            "--pymz-backend-source", "/path/to/backend.zig",
        ])
        assert opts.command == "build"
        assert opts.module == "_foo"
        assert opts.distribution == "foo"
        assert opts.package_dir == "python"
        assert opts.version == "0.1.0"
        assert opts.release is True
        assert opts.out == "dist"
        assert opts.runtime == "cpython3"
        assert opts.platform_tag == "manylinux_2_28_x86_64"
        assert opts.pymz_backend_source == "/path/to/backend.zig"

    def test_build_parser_accepts_matrix_flags():
        parser = _build_parser()
        opts = parser.parse_args([
            "matrix",
            "--runtimes", "cpython3,cpython3-limited",
            "--python-versions", "3.10,3.11,3.12",
            "--targets", "native,x86_64-linux-gnu",
            "--platform-tags", "any,manylinux_2_28_x86_64",
            "--release",
            "-o", "dist",
        ])
        assert opts.command == "matrix"
        assert opts.runtimes == "cpython3,cpython3-limited"
        assert opts.python_versions == "3.10,3.11,3.12"
        assert opts.targets == "native,x86_64-linux-gnu"
        assert opts.platform_tags == "any,manylinux_2_28_x86_64"

    def test_build_parser_accepts_develop_flags():
        parser = _build_parser()
        opts = parser.parse_args([
            "develop",
            "-o", "dist",
            "--runtime", "cpython3",
            "--zig-target", "example",
        ])
        assert opts.command == "develop"
        assert opts.out == "dist"
        assert opts.runtime == "cpython3"
        assert opts.zig_target == "example"

    def test_build_parser_accepts_config_command():
        parser = _build_parser()
        opts = parser.parse_args(["config"])
        assert opts.command == "config"

    def test_build_matrix_from_cli_cross_product():
        entries = build_matrix_from_cli(
            runtimes=["cpython3", "cpython3-limited"],
            python_versions=["3.10", "3.11"],
            targets=["native", "x86_64-linux-gnu"],
            platform_tags=["any", "manylinux_2_28_x86_64"],
        )
        # 2 runtimes x 2 versions x 2 targets = 8 entries
        assert len(entries) == 8
        # Check first entry
        assert entries[0].runtime == "cpython3"
        assert entries[0].version == "3.10"
        assert entries[0].target is None  # native -> None
        assert entries[0].platform_tag == "any"
        # Check cross-compile entry
        assert entries[1].runtime == "cpython3"
        assert entries[1].version == "3.10"
        assert entries[1].target == "x86_64-linux-gnu"
        assert entries[1].platform_tag == "manylinux_2_28_x86_64"

    def test_build_matrix_from_cli_defaults():
        entries = build_matrix_from_cli()
        # No params: 1 runtime (auto) x 0 versions x 1 target (native) = 0 entries
        assert len(entries) == 0
        entries = build_matrix_from_cli(python_versions=["3.12"])
        assert len(entries) == 1
        # Default runtime is "auto" (resolved to a concrete runtime at build time).
        assert entries[0].runtime == "auto"
        assert entries[0].version == "3.12"
        assert entries[0].target is None
