"""Identity-scoped structured procedural memory with atomic conflict control."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import stat
import threading
from collections.abc import Callable, Iterable, Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from ops_scaffold.contracts import (
    ContractError,
    Procedure,
    ProvenanceRef,
    RuntimeContext,
    SourceFamily,
)
from ops_scaffold.scoping import derive_opaque_scope, validate_scope_secret

_PROCEDURE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
_TEMP_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_MAX_FILE_BYTES = 65_536
_MAX_PROCEDURES = 256
_MAX_IDENTITIES = 10_000


class ProcedureConflictError(RuntimeError):
    """The caller attempted a stale create or update."""


class ProcedureStorageError(RuntimeError):
    """A safe bounded procedural-memory storage failure."""


class _IdentityWorkspaceMissing(FileNotFoundError):
    """The derived identity directory has not been created."""


class SecureProcedureService:
    """Store versioned JSON below an injected workspace using structured IDs only."""

    def __init__(
        self,
        root: Path,
        *,
        scope_secret: bytes,
        new_id: Callable[[], str],
        before_replace: Callable[[], None] | None = None,
    ) -> None:
        self._root = self._prepare_root(Path(root))
        self._scope_secret = validate_scope_secret(scope_secret)
        if not callable(new_id):
            raise TypeError("procedure identifier generator must be callable")
        if before_replace is not None and not callable(before_replace):
            raise TypeError("procedure write hook must be callable")
        self._new_id = new_id
        self._before_replace = before_replace
        self._locks: dict[str, threading.RLock] = {}
        self._locks_guard = threading.Lock()

    @property
    def root(self) -> Path:
        return self._root

    def list(self, context: RuntimeContext) -> Sequence[str]:
        identity = self._identity_scope(context)
        lock = self._identity_lock(identity)
        with lock:
            try:
                with self._identity_directory(identity, create=False) as directory_fd:
                    with os.scandir(directory_fd) as scan:
                        entries = sorted(scan, key=lambda item: item.name)
                        identifiers = self._validated_inventory(entries)
            except _IdentityWorkspaceMissing:
                return ()
            except OSError as exc:
                raise ProcedureStorageError("procedure inventory is unavailable") from exc
            return tuple(identifiers)

    def read(self, context: RuntimeContext, procedure_id: str) -> Procedure | None:
        self._validate_procedure_id(procedure_id)
        identity = self._identity_scope(context)
        lock = self._identity_lock(identity)
        with lock:
            try:
                with self._identity_directory(identity, create=False) as directory_fd:
                    raw = self._read_file(directory_fd, self._filename(procedure_id))
            except _IdentityWorkspaceMissing:
                return None
            except ProcedureStorageError:
                raise
            except OSError as exc:
                raise ProcedureStorageError("procedure read failed") from exc
            return self._decode(raw)

    def write(
        self,
        context: RuntimeContext,
        procedure: Procedure,
        *,
        expected_hash: str | None,
    ) -> str:
        if not isinstance(procedure, Procedure):
            raise ProcedureStorageError("procedure record is malformed")
        self._validate_procedure_id(procedure.procedure_id)
        if expected_hash is not None and (
            not isinstance(expected_hash, str) or not _SHA256.fullmatch(expected_hash)
        ):
            raise ProcedureConflictError("procedure update requires a valid expected hash")
        identity = self._identity_scope(context)
        lock = self._identity_lock(identity)
        encoded = self._encode(procedure)
        digest = hashlib.sha256(encoded).hexdigest()

        with lock:
            try:
                with self._identity_directory(
                    identity,
                    create=expected_hash is None,
                ) as directory_fd:
                    fcntl.flock(directory_fd, fcntl.LOCK_EX)
                    try:
                        with os.scandir(directory_fd) as scan:
                            identifiers = self._validated_inventory(scan)
                        self._check_expected_hash(
                            directory_fd,
                            self._filename(procedure.procedure_id),
                            expected_hash,
                            procedure_count=len(identifiers),
                        )
                        self._replace_file(
                            directory_fd,
                            self._filename(procedure.procedure_id),
                            encoded,
                        )
                    finally:
                        fcntl.flock(directory_fd, fcntl.LOCK_UN)
            except ProcedureConflictError:
                raise
            except _IdentityWorkspaceMissing as exc:
                raise ProcedureConflictError("procedure update expected hash is stale") from exc
            except ProcedureStorageError:
                raise
            except (OSError, ValueError, RuntimeError) as exc:
                raise ProcedureStorageError("procedure write failed") from exc
        return digest

    @staticmethod
    def _prepare_root(root: Path) -> Path:
        if not root.is_absolute():
            raise ValueError("procedure workspace must be an injected absolute path")
        current = Path(root.anchor)
        for component in root.parts[1:]:
            current /= component
            try:
                component_stat = os.lstat(current)
            except FileNotFoundError:
                break
            if stat.S_ISLNK(component_stat.st_mode):
                raise ValueError("procedure workspace must not contain symlinks")
        if root.exists():
            if root.is_symlink() or not root.is_dir():
                raise ValueError("procedure workspace must be a real directory")
        else:
            parent = root.parent
            if parent.is_symlink() or not parent.is_dir():
                raise ValueError("procedure workspace parent must be a real directory")
            root.mkdir(mode=0o700)
        return root

    def _identity_scope(self, context: RuntimeContext) -> str:
        if not isinstance(context, RuntimeContext):
            raise ProcedureStorageError("trusted runtime context is required")
        return derive_opaque_scope(
            self._scope_secret,
            "ops-copilot:procedure-identity:v1",
            context.identity_id,
            prefix="identity",
        )

    def _identity_lock(self, identity: str) -> threading.RLock:
        with self._locks_guard:
            lock = self._locks.get(identity)
            if lock is not None:
                return lock
            if len(self._locks) >= _MAX_IDENTITIES:
                raise ProcedureStorageError("procedure identity limit reached")
            lock = threading.RLock()
            self._locks[identity] = lock
            return lock

    @contextmanager
    def _identity_directory(self, identity: str, *, create: bool) -> Iterator[int]:
        root_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        root_fd = os.open(self._root, root_flags)
        try:
            if create:
                try:
                    os.mkdir(identity, mode=0o700, dir_fd=root_fd)
                except FileExistsError:
                    pass
            try:
                identity_stat = os.stat(
                    identity,
                    dir_fd=root_fd,
                    follow_symlinks=False,
                )
            except FileNotFoundError as exc:
                raise _IdentityWorkspaceMissing from exc
            if stat.S_ISLNK(identity_stat.st_mode) or not stat.S_ISDIR(identity_stat.st_mode):
                raise ProcedureStorageError("procedure identity workspace is invalid")
            identity_fd = os.open(identity, root_flags, dir_fd=root_fd)
        finally:
            os.close(root_fd)
        try:
            yield identity_fd
        finally:
            os.close(identity_fd)

    def _check_expected_hash(
        self,
        directory_fd: int,
        filename: str,
        expected_hash: str | None,
        *,
        procedure_count: int,
    ) -> None:
        try:
            current = self._read_file(directory_fd, filename)
        except FileNotFoundError as exc:
            if expected_hash is not None:
                raise ProcedureConflictError("procedure create expected an absent record") from exc
            if procedure_count >= _MAX_PROCEDURES:
                raise ProcedureStorageError("procedure inventory exceeds its bound") from exc
            return
        if expected_hash is None or not _SHA256.fullmatch(expected_hash):
            raise ProcedureConflictError("procedure update requires the current expected hash")
        current_hash = hashlib.sha256(current).hexdigest()
        if current_hash != expected_hash:
            raise ProcedureConflictError("procedure update expected hash is stale")

    def _replace_file(self, directory_fd: int, filename: str, encoded: bytes) -> None:
        if len(encoded) > _MAX_FILE_BYTES:
            raise ProcedureStorageError("procedure record exceeds its bound")
        try:
            temp_id = self._new_id()
        except Exception as exc:
            raise ProcedureStorageError("procedure temporary identifier failed") from exc
        if not isinstance(temp_id, str) or not _TEMP_ID.fullmatch(temp_id):
            raise ProcedureStorageError("procedure temporary identifier is invalid")
        temp_name = f".{filename}.{temp_id}.tmp"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        temp_fd: int | None = None
        created = False
        try:
            temp_fd = os.open(temp_name, flags, 0o600, dir_fd=directory_fd)
            created = True
            view = memoryview(encoded)
            while view:
                written = os.write(temp_fd, view)
                if written <= 0:
                    raise OSError("procedure temporary write made no progress")
                view = view[written:]
            os.fsync(temp_fd)
            os.close(temp_fd)
            temp_fd = None
            if self._before_replace is not None:
                self._before_replace()
            os.replace(
                temp_name,
                filename,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            os.fsync(directory_fd)
        finally:
            if temp_fd is not None:
                os.close(temp_fd)
            if created:
                try:
                    os.unlink(temp_name, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass

    @staticmethod
    def _read_file(directory_fd: int, filename: str) -> bytes:
        file_stat = os.stat(filename, dir_fd=directory_fd, follow_symlinks=False)
        if (
            stat.S_ISLNK(file_stat.st_mode)
            or not stat.S_ISREG(file_stat.st_mode)
            or not 1 <= file_stat.st_size <= _MAX_FILE_BYTES
        ):
            raise ProcedureStorageError("procedure record is not a bounded regular file")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        file_fd = os.open(filename, flags, dir_fd=directory_fd)
        try:
            opened_stat = os.fstat(file_fd)
            if opened_stat.st_ino != file_stat.st_ino or opened_stat.st_dev != file_stat.st_dev:
                raise ProcedureStorageError("procedure record changed during open")
            chunks: list[bytes] = []
            remaining = _MAX_FILE_BYTES + 1
            while remaining:
                chunk = os.read(file_fd, min(remaining, 16_384))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            if len(raw) > _MAX_FILE_BYTES:
                raise ProcedureStorageError("procedure record exceeds its bound")
            return raw
        finally:
            os.close(file_fd)

    @staticmethod
    def _encode(procedure: Procedure) -> bytes:
        value = {
            "schema_version": procedure.version,
            "procedure_id": procedure.procedure_id,
            "title": procedure.title,
            "steps": list(procedure.steps),
            "provenance": [
                {
                    "source_family": item.source_family.value,
                    "source_id": item.source_id,
                    "content_sha256": item.content_sha256,
                }
                for item in procedure.provenance
            ],
        }
        return json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()

    @staticmethod
    def _decode(raw: bytes) -> Procedure:
        try:
            value = json.loads(
                raw.decode("utf-8"),
                object_pairs_hook=_unique_object,
                parse_constant=_reject_constant,
            )
        except (UnicodeError, json.JSONDecodeError, ValueError) as exc:
            raise ProcedureStorageError("procedure record is invalid JSON") from exc
        if not isinstance(value, dict) or set(value) != {
            "schema_version",
            "procedure_id",
            "title",
            "steps",
            "provenance",
        }:
            raise ProcedureStorageError("procedure record fields are invalid")
        provenance_value = value["provenance"]
        if not isinstance(provenance_value, list) or len(provenance_value) > 64:
            raise ProcedureStorageError("procedure provenance is invalid")
        provenance: list[ProvenanceRef] = []
        try:
            for item in provenance_value:
                if not isinstance(item, dict) or set(item) != {
                    "source_family",
                    "source_id",
                    "content_sha256",
                }:
                    raise ProcedureStorageError("procedure provenance is invalid")
                provenance.append(
                    ProvenanceRef(
                        source_family=SourceFamily(item["source_family"]),
                        source_id=item["source_id"],
                        content_sha256=item["content_sha256"],
                    )
                )
            if not isinstance(value["steps"], list):
                raise ProcedureStorageError("procedure steps are invalid")
            return Procedure(
                procedure_id=value["procedure_id"],
                version=value["schema_version"],
                title=value["title"],
                steps=tuple(value["steps"]),
                provenance=tuple(provenance),
            )
        except (ContractError, TypeError, ValueError) as exc:
            raise ProcedureStorageError("procedure record contract is invalid") from exc

    @staticmethod
    def _filename(procedure_id: str) -> str:
        return f"{procedure_id}.json"

    @staticmethod
    def _validate_procedure_id(value: object) -> None:
        if not isinstance(value, str) or not _PROCEDURE_ID.fullmatch(value):
            raise ProcedureStorageError("procedure identifier must be structured and bounded")

    @staticmethod
    def _validated_inventory(entries: Iterable[os.DirEntry[str]]) -> list[str]:
        identifiers: list[str] = []
        for entry in entries:
            if entry.name.endswith(".tmp"):
                raise ProcedureStorageError("procedure workspace contains incomplete artifacts")
            if (
                entry.is_symlink()
                or not entry.is_file(follow_symlinks=False)
                or not entry.name.endswith(".json")
            ):
                raise ProcedureStorageError("procedure workspace contains invalid artifacts")
            identifier = entry.name.removesuffix(".json")
            SecureProcedureService._validate_procedure_id(identifier)
            identifiers.append(identifier)
        if len(identifiers) > _MAX_PROCEDURES:
            raise ProcedureStorageError("procedure inventory exceeds its bound")
        return identifiers


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def _reject_constant(_value: str) -> object:
    raise ValueError("non-finite JSON value")
