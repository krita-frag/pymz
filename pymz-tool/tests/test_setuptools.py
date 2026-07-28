from __future__ import absolute_import, print_function

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
        "pymz",
        "-Dpython-version=3.12",
    ]

if sys.version_info[0] >= 3:
    from pymz_tool.cli import (
        _split_csv, _split_backend_sources, _build_parser, _cmd_build,
    )
    from pymz_tool.matrix import (
        build_matrix_from_cli, run_zig_build, build_one_cell,
    )
    from pymz_tool import backend

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

    # --- 双参数 bug 回归测试 ---
    # 验证 pymz-tool build / PEP 517 build_wheel / PEP 660 build_editable
    # 三条路径不会同时传递 -Dpython-version 和 -Dpython-versions 给 zig build，
    # 避免 Zig 侧 error.InvalidOption。

    def test_run_zig_build_no_duplicate_python_version_flags(monkeypatch, tmp_path):
        """run_zig_build 不得同时传递 -Dpython-version 和 -Dpython-versions。"""
        captured_cmds = []  # type: list

        def fake_check_call(cmd, **kwargs):
            captured_cmds.append(cmd)

        monkeypatch.setattr("pymz_tool.matrix.subprocess.check_call", fake_check_call)

        run_zig_build(
            tmp_path, "example", tmp_path / "prefix",
            python_version="3.12",
        )

        assert len(captured_cmds) == 1
        cmd = captured_cmds[0]
        has_version = any(a.startswith("-Dpython-version=") for a in cmd)
        has_versions = any(a.startswith("-Dpython-versions=") for a in cmd)
        assert not (has_version and has_versions), \
            "run_zig_build 同时传递了 -Dpython-version 和 -Dpython-versions"

    def test_build_one_cell_single_version_no_dual_params(monkeypatch, tmp_path):
        """build_one_cell 单版本路径：python_versions 应为 None，不触发双参数 bug。"""
        captured_kwargs = {}  # type: dict

        def fake_run_zig_build(root, step, prefix, **kwargs):
            captured_kwargs.update(kwargs)

        def fake_build_wheel(out_dir, manifest, lib_dir, root):
            return "fake-0.1.0-cp312-cp312-linux_x86_64.whl"

        monkeypatch.setattr("pymz_tool.matrix.run_zig_build", fake_run_zig_build)
        monkeypatch.setattr("pymz_tool.matrix._build_wheel", fake_build_wheel)

        # 准备 prefix/lib 目录并放入伪扩展产物，使 collect_artifacts 能找到它
        prefix = tmp_path / "prefix"
        lib_dir = prefix / "lib"
        lib_dir.mkdir(parents=True)
        (lib_dir / "_fake.so").write_bytes(b"")

        project = {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "",
        }

        build_one_cell(
            tmp_path, "example", prefix, tmp_path, project,
            python_version="3.12",
        )

        assert captured_kwargs.get("python_version") == "3.12"
        assert captured_kwargs.get("python_versions") is None

    def test_build_one_cell_matrix_path_no_dual_params(monkeypatch, tmp_path):
        """build_one_cell 矩阵路径：python_version 应为 None，不触发双参数 bug。"""
        captured_kwargs = {}  # type: dict

        def fake_run_zig_build(root, step, prefix, **kwargs):
            captured_kwargs.update(kwargs)

        def fake_build_wheel(out_dir, manifest, lib_dir, root):
            return "fake-0.1.0-cp312-cp312-linux_x86_64.whl"

        monkeypatch.setattr("pymz_tool.matrix.run_zig_build", fake_run_zig_build)
        monkeypatch.setattr("pymz_tool.matrix._build_wheel", fake_build_wheel)

        prefix = tmp_path / "prefix"
        lib_dir = prefix / "lib"
        lib_dir.mkdir(parents=True)
        (lib_dir / "_fake.so").write_bytes(b"")

        project = {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "",
        }

        build_one_cell(
            tmp_path, "example", prefix, tmp_path, project,
            python_versions="3.12",
        )

        assert captured_kwargs.get("python_version") is None
        assert captured_kwargs.get("python_versions") == "3.12"

    def test_cli_build_no_dual_params(monkeypatch, tmp_path):
        """CLI build 命令调用链不触发双参数 bug。"""
        captured_kwargs = {}  # type: dict

        def fake_build_one_cell(root, step, prefix, out_dir, project, **kwargs):
            captured_kwargs.update(kwargs)
            return "fake-0.1.0-cp312-cp312-linux_x86_64.whl"

        monkeypatch.setattr("pymz_tool.cli.build_one_cell", fake_build_one_cell)
        monkeypatch.setattr("pymz_tool.cli.load_config", lambda root: {})
        monkeypatch.setattr("pymz_tool.cli.get_project_info", lambda root: {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "",
        })

        parser = _build_parser()
        opts = parser.parse_args(["build", "-o", str(tmp_path / "dist")])
        rc = _cmd_build(tmp_path, opts)

        assert rc == 0
        assert captured_kwargs.get("python_version") is not None
        assert captured_kwargs.get("python_versions") is None

    def test_build_wheel_no_dual_params(monkeypatch, tmp_path):
        """PEP 517 build_wheel 调用链不触发双参数 bug。"""
        captured_kwargs = {}  # type: dict

        def fake_build_one_cell(root, step, prefix, out_dir, project, **kwargs):
            captured_kwargs.update(kwargs)
            return "fake-0.1.0-cp312-cp312-linux_x86_64.whl"

        monkeypatch.setattr("pymz_tool.backend.build_one_cell", fake_build_one_cell)
        monkeypatch.setattr("pymz_tool.backend.load_config", lambda root: {})
        monkeypatch.setattr("pymz_tool.backend.get_project_info", lambda root: {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "",
        })

        wheel_dir = tmp_path / "dist"
        backend.build_wheel(str(wheel_dir))

        assert captured_kwargs.get("python_version") is not None
        assert captured_kwargs.get("python_versions") is None

    def test_build_editable_no_dual_params(monkeypatch, tmp_path):
        """PEP 660 build_editable 调用链不触发双参数 bug。"""
        captured_kwargs = {}  # type: dict

        def fake_build_and_manifest(root, step, prefix, project, **kwargs):
            captured_kwargs.update(kwargs)
            manifest = {"distribution": "fake", "version": "0.1.0", "package_dir": ""}
            # 返回空产物列表，避免文件复制
            return manifest, tmp_path, []

        def fake_build_editable_wheel(wheel_dir, distribution, version, package_root):
            return "fake-0.1.0-py3-none-any.whl"

        monkeypatch.setattr("pymz_tool.backend._build_and_manifest", fake_build_and_manifest)
        monkeypatch.setattr("pymz_tool.backend.build_editable_wheel", fake_build_editable_wheel)
        monkeypatch.setattr("pymz_tool.backend.load_config", lambda root: {})
        monkeypatch.setattr("pymz_tool.backend.get_project_info", lambda root: {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "python",
        })
        monkeypatch.chdir(tmp_path)

        wheel_dir = tmp_path / "dist"
        backend.build_editable(str(wheel_dir))

        assert captured_kwargs.get("python_version") is not None
        assert captured_kwargs.get("python_versions") is None

    def test_build_editable_passes_release_config_settings(monkeypatch, tmp_path):
        """build_editable 在 config_settings={'release': True} 时将 release=True 传给 _build_and_manifest。"""
        captured_kwargs = {}  # type: dict

        def fake_build_and_manifest(root, step, prefix, project, **kwargs):
            captured_kwargs.update(kwargs)
            return {}, tmp_path, []

        def fake_build_editable_wheel(wheel_dir, distribution, version, package_root):
            return "fake-0.1.0-py3-none-any.whl"

        monkeypatch.setattr("pymz_tool.backend._build_and_manifest", fake_build_and_manifest)
        monkeypatch.setattr("pymz_tool.backend.build_editable_wheel", fake_build_editable_wheel)
        monkeypatch.setattr("pymz_tool.backend.load_config", lambda root: {})
        monkeypatch.setattr("pymz_tool.backend.get_project_info", lambda root: {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "python",
        })
        monkeypatch.chdir(tmp_path)

        wheel_dir = tmp_path / "dist"
        backend.build_editable(str(wheel_dir), config_settings={"release": True})

        assert captured_kwargs.get("release") is True

    # --- wheel 平台标签测试 ---

    def test_runtime_is_abi3():
        from pymz_tool.wheel import _runtime_is_abi3
        assert _runtime_is_abi3("cpython3-limited") is True
        assert _runtime_is_abi3("cpython3") is False
        assert _runtime_is_abi3("cpython2") is False

    def test_extension_digits_cpython():
        from pymz_tool.wheel import _extension_digits
        assert _extension_digits("_jsonz", "_jsonz.cpython-314-darwin.so") == "314"
        assert _extension_digits("_jsonz", "_jsonz.cpython-310-x86_64-linux-gnu.so") == "310"
        assert _extension_digits("_jsonz", "_jsonz.abi3.so") == "abi3"
        assert _extension_digits("_jsonz", "_jsonz.so") is None

    def test_py_tag():
        from pymz_tool.wheel import _py_tag
        assert _py_tag("cpython3", "314", None) == "cp314"
        assert _py_tag("cpython3", None, "3.12") == "cp312"
        assert _py_tag("cpython3-limited", None, None) == "cp310"

    def test_abi_tag():
        from pymz_tool.wheel import _abi_tag
        assert _abi_tag("cpython3", "314") == "cp314"
        assert _abi_tag("cpython3-limited", None) == "abi3"
        assert _abi_tag("cpython3-limited", "abi3") == "abi3"

    def test_wheel_platform_tag_from_manifest():
        from pymz_tool.wheel import _wheel_platform_tag
        assert _wheel_platform_tag({"platform_tag": "manylinux_2_28_x86_64"}) == "manylinux_2_28_x86_64"
        assert _wheel_platform_tag({"platform_tag": "macosx_11_0_arm64"}) == "macosx_11_0_arm64"

    # --- sdist PKG-INFO 测试 ---

    def test_build_sdist_generates_pkg_info(monkeypatch, tmp_path):
        """build_sdist 在 tarball 中生成 PEP 643 兼容的 PKG-INFO。"""
        import tarfile as _tarfile

        monkeypatch.setattr("pymz_tool.backend.get_project_info", lambda root: {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "python",
        })
        monkeypatch.setattr("pymz_tool.backend.load_pyproject", lambda root: {
            "project": {
                "name": "fake",
                "version": "0.1.0",
                "description": "A fake package",
                "requires-python": ">=3.8",
            }
        })

        (tmp_path / "pyproject.toml").write_text("")
        monkeypatch.chdir(tmp_path)

        sdist_dir = tmp_path / "dist"
        sdist_dir.mkdir()
        result = backend.build_sdist(str(sdist_dir))

        assert result.endswith(".tar.gz")
        sdist_path = sdist_dir / result
        with _tarfile.open(str(sdist_path), "r:gz") as tar:
            names = tar.getnames()
            assert any(n.endswith("/PKG-INFO") for n in names), "PKG-INFO not found in sdist"
            pkg_info_name = [n for n in names if n.endswith("/PKG-INFO")][0]
            content = tar.extractfile(pkg_info_name).read().decode("utf-8")
            assert "Metadata-Version: 2.1" in content
            assert "Name: fake" in content
            assert "Version: 0.1.0" in content
            assert "Summary: A fake package" in content
            assert "Requires-Python: >=3.8" in content

    def test_build_sdist_filter_excludes_nested_dirs(monkeypatch, tmp_path):
        """_sdist_filter 排除嵌套的 dist/、build/ 等目录。"""
        import tarfile as _tarfile

        monkeypatch.setattr("pymz_tool.backend.get_project_info", lambda root: {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "python",
        })
        monkeypatch.setattr("pymz_tool.backend.load_pyproject", lambda root: {})

        (tmp_path / "pyproject.toml").write_text("")
        (tmp_path / "src").mkdir()
        (tmp_path / "src" / "dist").mkdir()
        (tmp_path / "src" / "dist" / "artifact.txt").write_text("should be excluded")
        (tmp_path / "src" / "keep.txt").write_text("should be included")
        monkeypatch.chdir(tmp_path)

        sdist_dir = tmp_path / "dist_output"
        sdist_dir.mkdir()
        result = backend.build_sdist(str(sdist_dir))

        sdist_path = sdist_dir / result
        with _tarfile.open(str(sdist_path), "r:gz") as tar:
            names = tar.getnames()
            assert not any("dist/artifact" in n for n in names), \
                "nested dist/ should be excluded"
            assert any("keep.txt" in n for n in names), \
                "keep.txt should be included"

    # --- build_editable 空 package_dir 守卫测试 ---

    def test_build_editable_raises_on_empty_package_dir(monkeypatch, tmp_path):
        """build_editable 在 package_dir 为空时抛出 PymzConfigError。"""
        from pymz_tool.errors import PymzConfigError

        monkeypatch.setattr("pymz_tool.backend._build_and_manifest", lambda *a, **kw: ({}, tmp_path, []))
        monkeypatch.setattr("pymz_tool.backend.load_config", lambda root: {})
        monkeypatch.setattr("pymz_tool.backend.get_project_info", lambda root: {
            "version": "0.1.0",
            "module": "_fake",
            "modules": [{"name": "_fake", "zig_target": "example"}],
            "distribution": "fake",
            "package_dir": "",
        })
        monkeypatch.chdir(tmp_path)

        with pytest.raises(PymzConfigError):
            backend.build_editable(str(tmp_path / "dist"))
