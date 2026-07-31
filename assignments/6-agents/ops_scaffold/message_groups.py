"""Safe message-boundary detection supplied to the compaction exercise."""

from __future__ import annotations

from dataclasses import dataclass

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, ToolMessage


@dataclass(frozen=True, slots=True)
class SafeMessagePartition:
    """Complete user turns and messages that compaction must leave untouched."""

    complete_groups: tuple[tuple[BaseMessage, ...], ...]
    protected_messages: tuple[BaseMessage, ...]


def split_safe_message_groups(
    messages: list[BaseMessage] | tuple[BaseMessage, ...],
) -> SafeMessagePartition:
    """Separate complete turns without splitting an AI/tool exchange."""

    if not isinstance(messages, (list, tuple)) or not all(
        isinstance(message, BaseMessage) for message in messages
    ):
        raise TypeError("message history must contain LangChain messages")

    segments: list[tuple[BaseMessage, ...]] = []
    protected: list[BaseMessage] = []
    current: list[BaseMessage] = []
    for message in messages:
        if isinstance(message, HumanMessage):
            if current:
                segments.append(tuple(current))
            current = [message]
        elif current:
            current.append(message)
        else:
            protected.append(message)
    if current:
        segments.append(tuple(current))

    complete: list[tuple[BaseMessage, ...]] = []
    for segment in segments:
        if _is_complete_group(segment):
            complete.append(segment)
        else:
            protected.extend(segment)
    return SafeMessagePartition(
        complete_groups=tuple(complete),
        protected_messages=tuple(protected),
    )


def _is_complete_group(messages: tuple[BaseMessage, ...]) -> bool:
    if not messages or not isinstance(messages[0], HumanMessage):
        return False
    pending_tool_calls: set[str] = set()
    terminal_answer_seen = False
    for message in messages[1:]:
        if isinstance(message, HumanMessage):
            return False
        if isinstance(message, AIMessage):
            if pending_tool_calls:
                return False
            if message.tool_calls:
                call_ids = [call.get("id") for call in message.tool_calls]
                if any(not isinstance(call_id, str) or not call_id for call_id in call_ids) or len(
                    set(call_ids)
                ) != len(call_ids):
                    return False
                pending_tool_calls.update(call_ids)
                terminal_answer_seen = False
            else:
                terminal_answer_seen = True
        elif isinstance(message, ToolMessage):
            if message.tool_call_id not in pending_tool_calls:
                return False
            pending_tool_calls.remove(message.tool_call_id)
        else:
            return False
    return terminal_answer_seen and not pending_tool_calls
