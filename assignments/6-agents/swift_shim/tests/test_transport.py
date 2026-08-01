"""The subprocess half of the transport, driven against a stub console.

The stub speaks the JSONL protocol and nothing else, so these tests exercise the argv, the
excerpts file, the deadline and the exit-code mapping without a model ever being called.
"""

# ruff: noqa: S101 - asserts are the point of a test module

from __future__ import annotations

import json
import os
import stat
import sys
import time
from pathlib import Path

import pytest

from eval.live import LiveContractError, ProviderTransientError
from swift_shim.quarantine import QuarantineIndex
from swift_shim.tests import fixtures
from swift_shim.tests.test_protocol import DATA_DIR, PACKAGE_DIR, scenario
from swift_shim.transport import SwiftCLIAgentTransport

_STUB = '''#!{python}
import json, os, sys, time

arguments = sys.argv[1:]
question = sys.stdin.read()
excerpts = arguments[arguments.index("--excerpts-file") + 1]
json.dump(
    {{"argv": arguments, "question": question}},
    open(os.environ["STUB_TRACE"], "w"),
)
time.sleep(float(os.environ.get("STUB_SLEEP", "0")))
with open(excerpts, "w") as handle:
    handle.write(os.environ["STUB_EXCERPTS"])
sys.stderr.write("Ops Copilot v2 — glass-box operator console\\n")
sys.stdout.write(os.environ["STUB_STDOUT"])
sys.exit(int(os.environ.get("STUB_EXIT", "0")))
'''


@pytest.fixture
def stub(tmp_path: Path) -> Path:
    path = tmp_path / "ops-cli-stub"
    path.write_text(_STUB.format(python=sys.executable))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def _environ(tmp_path: Path, run: tuple[list[str], list[str]], **overrides: str) -> dict[str, str]:
    stdout, excerpts = run
    return {
        **os.environ,
        "STUB_STDOUT": "".join(f"{line}\n" for line in stdout),
        "STUB_EXCERPTS": "".join(f"{line}\n" for line in excerpts),
        "STUB_TRACE": str(tmp_path / "trace.json"),
        **overrides,
    }


def _transport(stub: Path, tmp_path: Path, run, **overrides: str) -> SwiftCLIAgentTransport:
    return SwiftCLIAgentTransport(
        package_dir=PACKAGE_DIR,
        data_dir=DATA_DIR,
        executable=stub,
        quarantine=QuarantineIndex.from_data_directory(DATA_DIR),
        environ=_environ(tmp_path, run, **overrides),
    )


def test_a_scenario_becomes_one_prompt_and_one_outcome(stub: Path, tmp_path: Path) -> None:
    target = scenario("checkout-timeout-incident")
    transport = _transport(stub, tmp_path, fixtures.two_family_run())

    outcome = transport.invoke(target, deadline_monotonic=time.monotonic() + 30)

    trace = json.loads((tmp_path / "trace.json").read_text())
    assert trace["question"] == f"{target.question}\n"
    assert trace["argv"][:3] == ["--json", "--data", str(DATA_DIR)]
    assert "--excerpts-file" in trace["argv"]
    assert len(outcome.evidence) == 3
    assert len(outcome.evidence_excerpts) == 3


def test_each_scenario_gets_a_workspace_of_its_own(stub: Path, tmp_path: Path) -> None:
    target = scenario("checkout-timeout-incident")
    transport = _transport(stub, tmp_path, fixtures.two_family_run())

    transport.invoke(target, deadline_monotonic=time.monotonic() + 30)
    first = json.loads((tmp_path / "trace.json").read_text())["argv"]
    transport.invoke(target, deadline_monotonic=time.monotonic() + 30)
    second = json.loads((tmp_path / "trace.json").read_text())["argv"]

    workspace = first[first.index("--workspace") + 1]
    assert workspace != second[second.index("--workspace") + 1]
    assert not Path(workspace).exists()


def test_a_failed_turn_is_reported_as_a_transient_provider_failure(
    stub: Path,
    tmp_path: Path,
) -> None:
    transport = _transport(stub, tmp_path, fixtures.failed_run(), STUB_EXIT="1")

    with pytest.raises(ProviderTransientError):
        transport.invoke(scenario("checkout-timeout-incident"))


def test_a_usage_refusal_is_a_contract_failure(stub: Path, tmp_path: Path) -> None:
    transport = _transport(stub, tmp_path, fixtures.failed_run(), STUB_EXIT="64")

    with pytest.raises(LiveContractError):
        transport.invoke(scenario("checkout-timeout-incident"))


def test_a_clean_exit_without_a_turn_record_is_still_reported(
    stub: Path,
    tmp_path: Path,
) -> None:
    transport = _transport(stub, tmp_path, ([], []))

    with pytest.raises(ProviderTransientError):
        transport.invoke(scenario("checkout-timeout-incident"))


def test_an_exhausted_budget_is_never_spent_on_a_process(stub: Path, tmp_path: Path) -> None:
    transport = _transport(stub, tmp_path, fixtures.two_family_run())

    with pytest.raises(TimeoutError):
        transport.invoke(
            scenario("checkout-timeout-incident"),
            deadline_monotonic=time.monotonic() - 1,
        )
    assert not (tmp_path / "trace.json").exists()


def test_a_run_past_its_deadline_is_killed(stub: Path, tmp_path: Path) -> None:
    transport = _transport(stub, tmp_path, fixtures.two_family_run(), STUB_SLEEP="5")

    with pytest.raises(TimeoutError):
        transport.invoke(
            scenario("checkout-timeout-incident"),
            deadline_monotonic=time.monotonic() + 0.5,
        )


def test_a_missing_binary_is_a_contract_failure(tmp_path: Path) -> None:
    transport = SwiftCLIAgentTransport(
        package_dir=tmp_path,
        data_dir=DATA_DIR,
        executable=tmp_path / "absent",
        quarantine=QuarantineIndex.empty(),
        environ={**os.environ, "PATH": ""},
    )

    with pytest.raises(LiveContractError):
        transport.invoke(scenario("checkout-timeout-incident"))
