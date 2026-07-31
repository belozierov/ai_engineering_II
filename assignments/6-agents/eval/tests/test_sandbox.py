from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from ops_scaffold.contracts import SourceFamily, SourceStatus
from ops_scaffold.sandbox import SourceSandbox

PROJECT_ROOT = Path(__file__).resolve().parents[2]
SHIPPED_SOURCE = PROJECT_ROOT / "data" / "source" / "checkout-service"


def _sandbox(tmp_path: Path, *, max_file_bytes: int = 256, max_depth: int = 5) -> SourceSandbox:
    source = tmp_path / "source"
    workspace = tmp_path / "workspace"
    (source / "src").mkdir(parents=True)
    (source / "config").mkdir()
    (source / "logs").mkdir()
    workspace.mkdir()
    (source / "src" / "checkout.py").write_text(
        "def charge(order_id: str) -> str:\n    return 'synthetic-ok'\n",
        encoding="utf-8",
    )
    (source / "config" / "service.toml").write_text(
        'service = "checkout-service"\ndependency = "tax-service"\n',
        encoding="utf-8",
    )
    (source / "logs" / "checkout.log").write_text(
        "2026-07-20T12:01:00Z request_id=req-test-001 upstream tax-service timeout\n",
        encoding="utf-8",
    )
    return SourceSandbox(
        source,
        workspace_root=workspace,
        max_file_bytes=max_file_bytes,
        max_depth=max_depth,
        quarantined_paths={"logs/checkout.log": ("segment-log-instruction-test",)},
    )


def test_source_list_read_and_search_return_bounded_source_results(tmp_path: Path) -> None:
    sandbox = _sandbox(tmp_path)

    listing = sandbox.list_files()
    read = sandbox.read_file("config/service.toml", offset=0, limit=36)
    search = sandbox.search("tax-service", path=".", max_results=5)

    assert listing.status is SourceStatus.OK
    assert listing.source_family is SourceFamily.REPOSITORY
    assert listing.content.splitlines() == [
        "config/service.toml",
        "logs/checkout.log",
        "src/checkout.py",
    ]
    assert read.status is SourceStatus.OK
    assert read.content == 'service = "checkout-service"\ndepende'
    assert read.content_sha256 == hashlib.sha256(read.content.encode()).hexdigest()
    assert read.truncated is True
    assert 'config/service.toml:2:dependency = "tax-service"' in search.content
    assert "logs/checkout.log:1:" in search.content
    assert search.quarantined_segments == ("segment-log-instruction-test",)


def test_source_search_preserves_exact_utf8_truncation_boundary_and_metadata(
    tmp_path: Path,
) -> None:
    source = tmp_path / "boundary-source"
    workspace = tmp_path / "boundary-workspace"
    (source / "logs").mkdir(parents=True)
    workspace.mkdir()
    relative_path = "logs/boundary.log"
    threshold = 32_768
    lines: list[str] = []
    rendered: list[str] = []
    content_bytes = 0

    while True:
        line_number = len(lines) + 1
        prefix = f"{relative_path}:{line_number}:"
        base = "needle "
        separator_bytes = 1 if rendered else 0
        filler_budget = (
            threshold - content_bytes - separator_bytes - len(f"{prefix}{base}".encode())
        )
        if filler_budget <= 393 * 4:
            quotient, remainder = divmod(filler_budget, 4)
            remainder_character = {0: "", 1: "x", 2: "é", 3: "€"}[remainder]
            line = f"{base}{'🙂' * quotient}{remainder_character}"
            assert len(line) <= 400
            lines.append(line)
            rendered.append(f"{prefix}{line}")
            break
        line = f"{base}{'🙂' * 393}"
        lines.append(line)
        rendered_line = f"{prefix}{line}"
        rendered.append(rendered_line)
        content_bytes += separator_bytes + len(rendered_line.encode())

    lines.append("needle beyond the exact boundary")
    (source / relative_path).write_text("\n".join(lines), encoding="utf-8")
    sandbox = SourceSandbox(
        source,
        workspace_root=workspace,
        quarantined_paths={relative_path: ("segment-boundary-test",)},
        allowed_resources={relative_path: ("repository:logs/boundary.log",)},
    )

    result = sandbox.search("needle", max_results=50)

    assert result.status is SourceStatus.OK
    assert result.content == "\n".join(rendered)
    assert len(result.content.encode()) == threshold
    assert result.truncated is True
    assert result.quarantined_segments == ("segment-boundary-test",)
    assert result.allowed_resources == ("repository:logs/boundary.log",)


def test_source_search_marks_truncation_only_when_an_additional_match_exists(
    tmp_path: Path,
) -> None:
    sandbox = _sandbox(tmp_path)

    exact = sandbox.search("tax-service", max_results=2)
    limited = sandbox.search("tax-service", max_results=1)

    assert len(exact.content.splitlines()) == 2
    assert exact.truncated is False
    assert len(limited.content.splitlines()) == 1
    assert limited.truncated is True


@pytest.mark.parametrize(
    "path",
    [
        "/etc/passwd",
        "../source-sibling/secret.txt",
        "src/../../workspace/identity-test-1/procedure.json",
        "src/\x00checkout.py",
        "one/two/three/four/five/six/file.txt",
        "a" * 300,
    ],
)
def test_source_operations_block_malformed_or_escaping_paths(
    tmp_path: Path,
    path: str,
) -> None:
    sandbox = _sandbox(tmp_path)

    for result in (
        sandbox.list_files(path),
        sandbox.read_file(path),
        sandbox.search("checkout", path=path),
    ):
        assert result.status is SourceStatus.BLOCKED
        assert result.content == ""
        assert result.truncated is False


def test_source_blocks_sibling_prefix_absolute_path(tmp_path: Path) -> None:
    sandbox = _sandbox(tmp_path)
    sibling = tmp_path / "source-sibling"
    sibling.mkdir()
    (sibling / "secret.txt").write_text("synthetic-secret", encoding="utf-8")

    result = sandbox.read_file(str(sibling / "secret.txt"))

    assert result.status is SourceStatus.BLOCKED
    assert result.content == ""


def test_source_blocks_oversized_and_invalid_utf8_files_without_partial_output(
    tmp_path: Path,
) -> None:
    sandbox = _sandbox(tmp_path, max_file_bytes=64)
    source = sandbox.root
    (source / "logs" / "oversized.log").write_text("x" * 65, encoding="utf-8")
    (source / "logs" / "invalid.log").write_bytes(b"valid-prefix\xff")

    oversized = sandbox.read_file("logs/oversized.log", limit=8)
    invalid = sandbox.read_file("logs/invalid.log")

    assert oversized.status is SourceStatus.BLOCKED
    assert oversized.content == ""
    assert invalid.status is SourceStatus.FAILED
    assert invalid.content == ""


def test_source_blocks_intermediate_and_final_symlinks(tmp_path: Path) -> None:
    sandbox = _sandbox(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "sentinel.txt").write_text("outside-synthetic-sentinel", encoding="utf-8")
    try:
        (sandbox.root / "linked-dir").symlink_to(outside, target_is_directory=True)
        (sandbox.root / "linked-file").symlink_to(outside / "sentinel.txt")
    except OSError as exc:
        pytest.skip(f"symlinks unavailable: {exc}")

    intermediate = sandbox.read_file("linked-dir/sentinel.txt")
    final = sandbox.read_file("linked-file")

    assert intermediate.status is SourceStatus.BLOCKED
    assert intermediate.content == ""
    assert final.status is SourceStatus.BLOCKED
    assert final.content == ""


def test_source_is_read_only_and_does_not_mutate_files(tmp_path: Path) -> None:
    sandbox = _sandbox(tmp_path)
    before = {
        path.relative_to(sandbox.root): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sandbox.root.rglob("*")
        if path.is_file()
    }

    assert not hasattr(sandbox, "write_file")
    sandbox.list_files()
    sandbox.read_file("src/checkout.py")
    sandbox.search("synthetic")

    after = {
        path.relative_to(sandbox.root): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sandbox.root.rglob("*")
        if path.is_file()
    }
    assert after == before


@pytest.mark.parametrize(
    ("offset", "limit"),
    [(-1, 10), (257, 1), (0, 0), (0, 257), (True, 10), (0, False)],
)
def test_source_read_rejects_invalid_ranges(
    tmp_path: Path,
    offset: int,
    limit: int,
) -> None:
    sandbox = _sandbox(tmp_path)

    result = sandbox.read_file("src/checkout.py", offset=offset, limit=limit)

    assert result.status is SourceStatus.BLOCKED
    assert result.content == ""


def test_source_roots_must_be_separate(tmp_path: Path) -> None:
    source = tmp_path / "source"
    source.mkdir()

    with pytest.raises(ValueError, match="separate"):
        SourceSandbox(source, workspace_root=source / "workspace")


def test_source_manifest_supplies_quarantine_markers_inside_sandbox(tmp_path: Path) -> None:
    sandbox = SourceSandbox.from_manifest(
        SHIPPED_SOURCE,
        workspace_root=tmp_path / "workspace" / "identity-test-1",
    )

    result = sandbox.read_file("logs/maintenance.log")

    assert result.status is SourceStatus.OK
    assert result.quarantined_segments == ("segment-source-maintenance-001",)
