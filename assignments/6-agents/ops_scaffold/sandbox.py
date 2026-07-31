"""Read-only, descriptor-relative access to the synthetic source snapshot."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from collections.abc import Mapping, Sequence
from pathlib import Path, PurePosixPath

from ops_scaffold.contracts import SourceFamily, SourceResult, SourceStatus

_EMPTY_DIGEST = hashlib.sha256(b"").hexdigest()
_PATH_LIMIT = 256
_COMPONENT_LIMIT = 100
_QUERY_LIMIT = 128
_MAX_RESULTS_LIMIT = 50
_LIST_OUTPUT_BYTES = 32_768
_SEARCH_OUTPUT_BYTES = 32_768
_RESOURCE = re.compile(r"(?:repository|monitoring|runbook):[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}\Z")


class _BlockedPath(ValueError):
    """An untrusted path or range violated the source capability contract."""


class SourceSandbox:
    """Narrow list/read/search access rooted at one immutable source directory.

    Paths are opened component-by-component relative to directory descriptors
    with ``O_NOFOLLOW``. This makes lexical containment checks and symlink
    checks part of the actual open operation instead of a racy pre-check.
    """

    def __init__(
        self,
        root: Path,
        *,
        workspace_root: Path,
        max_file_bytes: int = 262_144,
        max_depth: int = 8,
        max_entries: int = 256,
        quarantined_paths: Mapping[str, Sequence[str]] | None = None,
        allowed_resources: Mapping[str, Sequence[str]] | None = None,
    ) -> None:
        root_path = Path(root)
        workspace_path = Path(workspace_root)
        if root_path.is_symlink():
            raise ValueError("source root must not be a symlink")
        if not root_path.is_dir():
            raise ValueError("source root must be an existing directory")
        self._root = root_path.resolve(strict=True)
        self._workspace_root = workspace_path.resolve(strict=False)
        if self._overlaps(self._root, self._workspace_root):
            raise ValueError("source and workspace roots must be separate")
        if (
            type(max_file_bytes) is not int
            or not 1 <= max_file_bytes <= 262_144
            or type(max_depth) is not int
            or not 1 <= max_depth <= 16
            or type(max_entries) is not int
            or not 1 <= max_entries <= 2_048
        ):
            raise ValueError("sandbox limits must be positive bounded integers")
        self._max_file_bytes = max_file_bytes
        self._max_depth = max_depth
        self._max_entries = max_entries
        self._quarantined_paths = self._validate_quarantine_map(quarantined_paths or {})
        self._allowed_resources = self._validate_resource_map(allowed_resources or {})

    @property
    def root(self) -> Path:
        """Return the trusted configured root, never a model-controlled path."""

        return self._root

    @classmethod
    def from_manifest(
        cls,
        root: Path,
        *,
        workspace_root: Path,
        max_file_bytes: int = 262_144,
        max_depth: int = 8,
        max_entries: int = 256,
    ) -> SourceSandbox:
        """Create a sandbox whose quarantine markers come from its own manifest."""

        initial = cls(
            root,
            workspace_root=workspace_root,
            max_file_bytes=max_file_bytes,
            max_depth=max_depth,
            max_entries=max_entries,
        )
        manifest_result = initial.read_file("manifest.json")
        if manifest_result.status is not SourceStatus.OK:
            raise ValueError("source manifest is unavailable")
        try:
            manifest = json.loads(manifest_result.content)
        except json.JSONDecodeError as exc:
            raise ValueError("source manifest is invalid") from exc
        if (
            not isinstance(manifest, dict)
            or manifest.get("schema_version") != 1
            or manifest.get("synthetic") is not True
            or manifest.get("read_only") is not True
            or not isinstance(manifest.get("files"), list)
        ):
            raise ValueError("source manifest is invalid")
        quarantine: dict[str, tuple[str, ...]] = {}
        allowed_resources: dict[str, tuple[str, ...]] = {}
        for item in manifest["files"]:
            if (
                not isinstance(item, dict)
                or not isinstance(item.get("path"), str)
                or not isinstance(item.get("quarantined_segments"), list)
                or not isinstance(item.get("allowed_resources"), list)
                or item.get("trust") not in {"untrusted_data", "quarantined"}
            ):
                raise ValueError("source manifest is invalid")
            markers = tuple(item["quarantined_segments"])
            if markers:
                quarantine[item["path"]] = markers
            resources = tuple(item["allowed_resources"])
            if resources:
                allowed_resources[item["path"]] = resources
        return cls(
            root,
            workspace_root=workspace_root,
            max_file_bytes=max_file_bytes,
            max_depth=max_depth,
            max_entries=max_entries,
            quarantined_paths=quarantine,
            allowed_resources=allowed_resources,
        )

    def list_files(self, path: str = ".") -> SourceResult:
        """List regular files below a bounded relative directory."""

        operation = "list"
        try:
            parts = self._validate_path(path, allow_root=True)
            directory_fd = self._open_directory(parts)
            try:
                paths = self._walk_files(directory_fd, parts)
            finally:
                os.close(directory_fd)
            selected: list[str] = []
            truncated = False
            content_bytes = 0
            for item in paths:
                item_bytes = len(item.encode("utf-8")) + (1 if selected else 0)
                if content_bytes + item_bytes > _LIST_OUTPUT_BYTES:
                    truncated = True
                    break
                selected.append(item)
                content_bytes += item_bytes
            content = "\n".join(selected)
            return self._result(
                operation,
                path,
                SourceStatus.OK,
                content,
                truncated=truncated,
            )
        except _BlockedPath:
            return self._result(operation, path, SourceStatus.BLOCKED, "")
        except (FileNotFoundError, NotADirectoryError):
            return self._result(operation, path, SourceStatus.NOT_FOUND, "")
        except (OSError, UnicodeError):
            return self._result(operation, path, SourceStatus.FAILED, "")

    def read_file(
        self,
        path: str,
        *,
        offset: int = 0,
        limit: int | None = None,
    ) -> SourceResult:
        """Read one bounded UTF-8 file range without following symlinks."""

        operation = "read"
        effective_limit = self._max_file_bytes if limit is None else limit
        try:
            parts = self._validate_path(path, allow_root=False)
            if (
                type(offset) is not int
                or not 0 <= offset <= self._max_file_bytes
                or type(effective_limit) is not int
                or not 1 <= effective_limit <= self._max_file_bytes
            ):
                raise _BlockedPath
            file_fd, file_size = self._open_regular_file(parts)
            try:
                if file_size > self._max_file_bytes:
                    raise _BlockedPath
                os.lseek(file_fd, offset, os.SEEK_SET)
                raw = self._read_bounded(file_fd, effective_limit)
            finally:
                os.close(file_fd)
            content = raw.decode("utf-8")
            truncated = offset > 0 or offset + len(raw) < file_size
            return self._result(
                operation,
                path,
                SourceStatus.OK,
                content,
                truncated=truncated,
                quarantined=self._markers_for(path),
                allowed_resources=self._resources_for(path),
            )
        except _BlockedPath:
            return self._result(operation, path, SourceStatus.BLOCKED, "")
        except UnicodeError:
            return self._result(operation, path, SourceStatus.FAILED, "")
        except (FileNotFoundError, NotADirectoryError):
            return self._result(operation, path, SourceStatus.NOT_FOUND, "")
        except OSError:
            return self._result(operation, path, SourceStatus.BLOCKED, "")

    def search(
        self,
        query: str,
        *,
        path: str = ".",
        max_results: int = 20,
        _scoped_paths: frozenset[str] | None = None,
    ) -> SourceResult:
        """Search bounded UTF-8 files for a literal case-insensitive string."""

        operation = "search"
        try:
            if (
                not isinstance(query, str)
                or not query.strip()
                or "\x00" in query
                or len(query) > _QUERY_LIMIT
                or type(max_results) is not int
                or not 1 <= max_results <= _MAX_RESULTS_LIMIT
                or (
                    _scoped_paths is not None
                    and (
                        not isinstance(_scoped_paths, frozenset)
                        or any(not isinstance(item, str) for item in _scoped_paths)
                    )
                )
            ):
                raise _BlockedPath
            if _scoped_paths is not None:
                for scoped_path in _scoped_paths:
                    self._validate_path(scoped_path, allow_root=False)
            parts = self._validate_path(path, allow_root=True)
            directory_fd = self._open_directory(parts)
            try:
                paths = self._walk_files(directory_fd, parts)
            finally:
                os.close(directory_fd)

            matches: list[str] = []
            markers: set[str] = set()
            allowed_resources: set[str] = set()
            content_bytes = 0
            needle = query.casefold()
            for relative_path in paths:
                if _scoped_paths is not None and relative_path not in _scoped_paths:
                    continue
                file_parts = self._validate_path(relative_path, allow_root=False)
                file_fd, file_size = self._open_regular_file(file_parts)
                try:
                    if file_size > self._max_file_bytes:
                        raise _BlockedPath
                    raw = self._read_bounded(file_fd, self._max_file_bytes)
                finally:
                    os.close(file_fd)
                text = raw.decode("utf-8")
                for line_number, line in enumerate(text.splitlines(), start=1):
                    if needle not in line.casefold():
                        continue
                    if len(matches) >= max_results:
                        return self._result(
                            operation,
                            f"{path}:{query}",
                            SourceStatus.OK,
                            "\n".join(matches),
                            truncated=True,
                            quarantined=tuple(sorted(markers)),
                            allowed_resources=tuple(sorted(allowed_resources)),
                        )
                    rendered = f"{relative_path}:{line_number}:{line[:400]}"
                    rendered_bytes = len(rendered.encode("utf-8")) + (1 if matches else 0)
                    if content_bytes + rendered_bytes > _SEARCH_OUTPUT_BYTES:
                        return self._result(
                            operation,
                            f"{path}:{query}",
                            SourceStatus.OK,
                            "\n".join(matches),
                            truncated=True,
                            quarantined=tuple(sorted(markers)),
                            allowed_resources=tuple(sorted(allowed_resources)),
                        )
                    matches.append(rendered)
                    content_bytes += rendered_bytes
                    markers.update(self._markers_for(relative_path))
                    allowed_resources.update(self._resources_for(relative_path))
            return self._result(
                operation,
                f"{path}:{query}",
                SourceStatus.OK,
                "\n".join(matches),
                quarantined=tuple(sorted(markers)),
                allowed_resources=tuple(sorted(allowed_resources)),
            )
        except _BlockedPath:
            return self._result(operation, path, SourceStatus.BLOCKED, "")
        except UnicodeError:
            return self._result(operation, path, SourceStatus.FAILED, "")
        except (FileNotFoundError, NotADirectoryError):
            return self._result(operation, path, SourceStatus.NOT_FOUND, "")
        except OSError:
            return self._result(operation, path, SourceStatus.BLOCKED, "")

    @staticmethod
    def _overlaps(first: Path, second: Path) -> bool:
        return first == second or first in second.parents or second in first.parents

    def _validate_path(self, value: str, *, allow_root: bool) -> tuple[str, ...]:
        if (
            not isinstance(value, str)
            or "\x00" in value
            or len(value) > _PATH_LIMIT
            or Path(value).is_absolute()
            or value.startswith(("/", "\\"))
        ):
            raise _BlockedPath
        pure = PurePosixPath(value)
        parts = tuple(part for part in pure.parts if part not in ("", "."))
        if not parts and not allow_root:
            raise _BlockedPath
        if (
            any(part == ".." or len(part) > _COMPONENT_LIMIT for part in parts)
            or len(parts) > self._max_depth
        ):
            raise _BlockedPath
        return parts

    def _open_root(self) -> int:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        return os.open(self._root, flags)

    def _open_directory(self, parts: tuple[str, ...]) -> int:
        current_fd = self._open_root()
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            for part in parts:
                component_stat = os.stat(part, dir_fd=current_fd, follow_symlinks=False)
                if stat.S_ISLNK(component_stat.st_mode):
                    raise _BlockedPath
                next_fd = os.open(part, flags, dir_fd=current_fd)
                os.close(current_fd)
                current_fd = next_fd
            return current_fd
        except BaseException:
            os.close(current_fd)
            raise

    def _open_regular_file(self, parts: tuple[str, ...]) -> tuple[int, int]:
        parent_fd = self._open_directory(parts[:-1])
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        try:
            component_stat = os.stat(parts[-1], dir_fd=parent_fd, follow_symlinks=False)
            if stat.S_ISLNK(component_stat.st_mode):
                raise _BlockedPath
            file_fd = os.open(parts[-1], flags, dir_fd=parent_fd)
        finally:
            os.close(parent_fd)
        file_stat = os.fstat(file_fd)
        if not stat.S_ISREG(file_stat.st_mode):
            os.close(file_fd)
            raise _BlockedPath
        return file_fd, file_stat.st_size

    def _walk_files(
        self,
        directory_fd: int,
        prefix: tuple[str, ...],
    ) -> list[str]:
        output: list[str] = []

        def walk(current_fd: int, current: tuple[str, ...]) -> None:
            try:
                entries = sorted(os.scandir(current_fd), key=lambda item: item.name)
            except OSError as exc:
                raise _BlockedPath from exc
            for entry in entries:
                relative = (*current, entry.name)
                if len(relative) > self._max_depth:
                    raise _BlockedPath
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    child_fd = os.open(
                        entry.name,
                        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=current_fd,
                    )
                    try:
                        walk(child_fd, relative)
                    finally:
                        os.close(child_fd)
                elif entry.is_file(follow_symlinks=False):
                    output.append(PurePosixPath(*relative).as_posix())
                    if len(output) > self._max_entries:
                        raise _BlockedPath

        walk(directory_fd, prefix)
        return output

    @staticmethod
    def _read_bounded(file_fd: int, limit: int) -> bytes:
        chunks: list[bytes] = []
        remaining = limit
        while remaining:
            chunk = os.read(file_fd, min(remaining, 65_536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _markers_for(self, path: str) -> tuple[str, ...]:
        normalized = PurePosixPath(path).as_posix()
        return self._quarantined_paths.get(normalized, ())

    def _resources_for(self, path: str) -> tuple[str, ...]:
        normalized = PurePosixPath(path).as_posix()
        return self._allowed_resources.get(normalized, ())

    def _validate_quarantine_map(
        self,
        value: Mapping[str, Sequence[str]],
    ) -> dict[str, tuple[str, ...]]:
        validated: dict[str, tuple[str, ...]] = {}
        for path, markers in value.items():
            parts = self._validate_path(path, allow_root=False)
            normalized = PurePosixPath(*parts).as_posix()
            marker_tuple = tuple(markers)
            if any(
                not isinstance(marker, str)
                or not marker
                or len(marker) > 128
                or not all(character.isalnum() or character in "._:-" for character in marker)
                for marker in marker_tuple
            ):
                raise ValueError("quarantine markers must be bounded identifiers")
            validated[normalized] = marker_tuple
        return validated

    def _validate_resource_map(
        self,
        value: Mapping[str, Sequence[str]],
    ) -> dict[str, tuple[str, ...]]:
        validated: dict[str, tuple[str, ...]] = {}
        for path, resources in value.items():
            parts = self._validate_path(path, allow_root=False)
            normalized = PurePosixPath(*parts).as_posix()
            resource_tuple = tuple(resources)
            if len(resource_tuple) > 128 or any(
                not isinstance(resource, str) or not _RESOURCE.fullmatch(resource)
                for resource in resource_tuple
            ):
                raise ValueError("source resource scopes must be bounded identifiers")
            if len(set(resource_tuple)) != len(resource_tuple):
                raise ValueError("source resource scopes must be bounded identifiers")
            validated[normalized] = resource_tuple
        return validated

    @staticmethod
    def _result(
        operation: str,
        locator: str,
        status: SourceStatus,
        content: str,
        *,
        truncated: bool = False,
        quarantined: tuple[str, ...] = (),
        allowed_resources: tuple[str, ...] = (),
    ) -> SourceResult:
        locator_digest = hashlib.sha256(locator.encode("utf-8", errors="replace")).hexdigest()[:16]
        content_digest = (
            hashlib.sha256(content.encode("utf-8")).hexdigest() if content else _EMPTY_DIGEST
        )
        return SourceResult(
            source_family=SourceFamily.REPOSITORY,
            source_id=f"repository:{operation}:{locator_digest}",
            status=status,
            content=content,
            content_sha256=content_digest,
            truncated=truncated,
            quarantined_segments=quarantined,
            allowed_resources=allowed_resources,
        )
