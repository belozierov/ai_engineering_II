"""Deterministic, finite evaluator doubles for public LangChain v1 APIs."""

from __future__ import annotations

import hashlib
import threading
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass
from typing import Any

from langchain_core.callbacks import CallbackManagerForLLMRun
from langchain_core.embeddings import Embeddings
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, BaseMessage
from langchain_core.outputs import ChatGeneration, ChatResult
from pydantic import ConfigDict, Field, PrivateAttr
from typing_extensions import override


class ScriptExhaustedError(RuntimeError):
    """A finite model was invoked after its declared script ended."""


class UnboundToolError(RuntimeError):
    """A scripted response attempted a tool outside the public binding path."""


@dataclass(frozen=True, slots=True)
class AgentPayload:
    messages: tuple[dict[str, object], ...]


@dataclass(frozen=True, slots=True)
class SummaryPayload:
    history: tuple[dict[str, object], ...]


@dataclass(frozen=True, slots=True)
class JudgePayload:
    question: str
    answer: str
    evidence: tuple[dict[str, object], ...]


class AgentPayloadCapture:
    """Capture only the conversation payload passed to the agent provider."""

    def __init__(self) -> None:
        self.requests: list[AgentPayload] = []
        self._lock = threading.Lock()

    def capture(self, messages: Sequence[BaseMessage]) -> None:
        payload = AgentPayload(messages=tuple(_message_payload(message) for message in messages))
        with self._lock:
            self.requests.append(payload)

    def as_public_data(self) -> list[dict[str, object]]:
        with self._lock:
            return [asdict(request) for request in self.requests]


class SummaryPayloadCapture:
    """Capture only the bounded old-history partition sent for summarization."""

    def __init__(self) -> None:
        self.requests: list[SummaryPayload] = []
        self._lock = threading.Lock()

    def capture(self, history: Sequence[BaseMessage]) -> None:
        payload = SummaryPayload(history=tuple(_message_payload(message) for message in history))
        with self._lock:
            self.requests.append(payload)

    def as_public_data(self) -> list[dict[str, object]]:
        with self._lock:
            return [asdict(request) for request in self.requests]


class JudgePayloadCapture:
    """Capture only the bounded grounding-judge contract."""

    def __init__(self) -> None:
        self.requests: list[JudgePayload] = []
        self._lock = threading.Lock()

    def capture(
        self,
        *,
        question: str,
        answer: str,
        evidence: Sequence[Mapping[str, object]],
    ) -> None:
        payload = JudgePayload(
            question=question,
            answer=answer,
            evidence=tuple(dict(item) for item in evidence),
        )
        with self._lock:
            self.requests.append(payload)

    def as_public_data(self) -> list[dict[str, object]]:
        with self._lock:
            return [asdict(request) for request in self.requests]


class FiniteScriptedChatModel(BaseChatModel):
    """Finite BaseChatModel that supports the create_agent tool-binding path."""

    model_config = ConfigDict(arbitrary_types_allowed=True)

    script: list[AIMessage]
    capture: AgentPayloadCapture = Field(default_factory=AgentPayloadCapture)
    _position: int = PrivateAttr(default=0)
    _invocation_count: int = PrivateAttr(default=0)
    _bound_tool_names: frozenset[str] = PrivateAttr(default_factory=frozenset)
    _tools_were_bound: bool = PrivateAttr(default=False)
    _lock: threading.Lock = PrivateAttr(default_factory=threading.Lock)

    @property
    def invocation_count(self) -> int:
        return self._invocation_count

    @property
    def bound_tool_names(self) -> frozenset[str]:
        return self._bound_tool_names

    @property
    @override
    def _llm_type(self) -> str:
        return "ops-copilot-finite-scripted"

    @override
    def bind_tools(
        self,
        tools: Sequence[dict[str, Any] | type | Any],
        *,
        tool_choice: str | None = None,
        **kwargs: Any,
    ) -> FiniteScriptedChatModel:
        del tool_choice, kwargs
        names: set[str] = set()
        for tool in tools:
            name = _tool_name(tool)
            if name is None:
                raise UnboundToolError("tool binding contains an unsupported tool")
            names.add(name)
        self._bound_tool_names = frozenset(names)
        self._tools_were_bound = True
        return self

    @override
    def _generate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: Any,
    ) -> ChatResult:
        del stop, run_manager, kwargs
        with self._lock:
            self.capture.capture(messages)
            self._invocation_count += 1
            if self._position >= len(self.script):
                raise ScriptExhaustedError("script exhausted")
            response = self.script[self._position]
            self._position += 1
        called = {call["name"] for call in response.tool_calls}
        if called and (not self._tools_were_bound or not called.issubset(self._bound_tool_names)):
            raise UnboundToolError("scripted response requested an unbound tool")
        return ChatResult(generations=[ChatGeneration(message=response)])


class DeterministicSummaryModel:
    """Small summary double with an outbound payload class distinct from agent calls."""

    def __init__(
        self,
        summary: str = "Untrusted synthetic history summary.",
        *,
        capture: SummaryPayloadCapture | None = None,
    ) -> None:
        self.summary = summary
        self.capture = capture or SummaryPayloadCapture()

    def summarize(self, history: Sequence[BaseMessage]) -> str:
        self.capture.capture(history)
        return self.summary


class DeterministicJudgeModel:
    """Grounding-judge double that sees no runtime or memory internals."""

    def __init__(
        self,
        *,
        verdict: bool = True,
        capture: JudgePayloadCapture | None = None,
    ) -> None:
        self.verdict = verdict
        self.capture = capture or JudgePayloadCapture()

    def judge(
        self,
        *,
        question: str,
        answer: str,
        evidence: Sequence[Mapping[str, object]],
    ) -> bool:
        self.capture.capture(question=question, answer=answer, evidence=evidence)
        return self.verdict


class DeterministicEmbeddings(Embeddings):
    """Stable local embeddings suitable for real InMemoryStore integration tests."""

    def __init__(self, *, dimensions: int = 32) -> None:
        if type(dimensions) is not int or not 8 <= dimensions <= 1_024:
            raise ValueError("embedding dimensions must be bounded")
        self.dimensions = dimensions

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return [self._embed(text) for text in texts]

    def embed_query(self, text: str) -> list[float]:
        return self._embed(text)

    def _embed(self, text: str) -> list[float]:
        vector = [0.0] * self.dimensions
        for token in text.casefold().split():
            digest = hashlib.sha256(token.encode()).digest()
            vector[int.from_bytes(digest[:2], "big") % self.dimensions] += 1.0
        return vector


class DeterministicClock:
    def __init__(self, start: float = 1_000.0) -> None:
        self._value = float(start)
        self._lock = threading.Lock()

    def __call__(self) -> float:
        with self._lock:
            return self._value

    def advance(self, seconds: float) -> float:
        with self._lock:
            self._value += float(seconds)
            return self._value


class DeterministicIdGenerator:
    def __init__(self, *, prefix: str = "id-test") -> None:
        self._prefix = prefix
        self._value = 0
        self._lock = threading.Lock()

    def __call__(self) -> str:
        with self._lock:
            self._value += 1
            return f"{self._prefix}-{self._value}"


class SequenceIdGenerator:
    """Finite IDs used to prove collisions and exhaustion deterministically."""

    def __init__(self, values: Sequence[str]) -> None:
        self._values = tuple(values)
        self._position = 0
        self._lock = threading.Lock()

    def __call__(self) -> str:
        with self._lock:
            if self._position >= len(self._values):
                raise RuntimeError("identifier script exhausted")
            value = self._values[self._position]
            self._position += 1
            return value


def _message_payload(message: BaseMessage) -> dict[str, object]:
    payload: dict[str, object] = {
        "type": message.type,
        "content": message.content,
    }
    if isinstance(message, AIMessage) and message.tool_calls:
        payload["tool_calls"] = [
            {
                "name": call["name"],
                "args": call["args"],
                "id": call["id"],
            }
            for call in message.tool_calls
        ]
    tool_call_id = getattr(message, "tool_call_id", None)
    if isinstance(tool_call_id, str):
        payload["tool_call_id"] = tool_call_id
    return payload


def _tool_name(tool: object) -> str | None:
    if isinstance(tool, dict):
        function = tool.get("function")
        if isinstance(function, dict) and isinstance(function.get("name"), str):
            return function["name"]
        return tool.get("name") if isinstance(tool.get("name"), str) else None
    name = getattr(tool, "name", None)
    if isinstance(name, str):
        return name
    fallback = getattr(tool, "__name__", None)
    return fallback if isinstance(fallback, str) else None
