"""Shared, import-safe infrastructure contracts for the Ops Copilot capstone.

Importing this package does not read data, contact a provider, load an index, or
construct runtime services. Entrypoints call the explicit bootstrap layer.
"""

from ops_scaffold.bootstrap import RuntimeServices, bootstrap_runtime
from ops_scaffold.config import (
    ALLOWED_PACKAGES,
    DEFAULT_PACKAGE,
    ConfigurationError,
    OpsSettings,
    TokenBudgets,
    select_package,
)
from ops_scaffold.contracts import (
    EVENT_SCHEMA_VERSION,
    PROCEDURE_SCHEMA_VERSION,
    AgentRuntime,
    AppEvent,
    ContractError,
    EventSink,
    EventStatus,
    EventType,
    Evidence,
    EvidenceRegistry,
    EvidenceStatus,
    IdentityNamespace,
    MemoryLevel,
    PackageFactory,
    Procedure,
    ProcedureService,
    ProvenanceRef,
    RuntimeChannel,
    RuntimeContext,
    ServiceBundle,
    SourceFamily,
    SourceResult,
    SourceStatus,
    TrustLabel,
)
from ops_scaffold.events import (
    CollectingEventSink,
    EventNormalizer,
    MetadataEventFactory,
    event_to_public_dict,
)
from ops_scaffold.evidence import EvidenceRegistryError, TurnEvidenceRegistry
from ops_scaffold.procedures import (
    ProcedureConflictError,
    ProcedureStorageError,
    SecureProcedureService,
)
from ops_scaffold.runner import (
    TurnBlocked,
    TurnBudgetExceeded,
    TurnCancelled,
    TurnResult,
    run_turn,
)

__all__ = [
    "ALLOWED_PACKAGES",
    "DEFAULT_PACKAGE",
    "EVENT_SCHEMA_VERSION",
    "PROCEDURE_SCHEMA_VERSION",
    "AgentRuntime",
    "AppEvent",
    "CollectingEventSink",
    "ConfigurationError",
    "ContractError",
    "EventNormalizer",
    "EventSink",
    "EventStatus",
    "EventType",
    "Evidence",
    "EvidenceRegistry",
    "EvidenceRegistryError",
    "EvidenceStatus",
    "IdentityNamespace",
    "MemoryLevel",
    "MetadataEventFactory",
    "OpsSettings",
    "PackageFactory",
    "Procedure",
    "ProcedureConflictError",
    "ProcedureService",
    "ProcedureStorageError",
    "ProvenanceRef",
    "RuntimeChannel",
    "RuntimeContext",
    "RuntimeServices",
    "SecureProcedureService",
    "ServiceBundle",
    "SourceFamily",
    "SourceResult",
    "SourceStatus",
    "TokenBudgets",
    "TrustLabel",
    "TurnBlocked",
    "TurnBudgetExceeded",
    "TurnCancelled",
    "TurnEvidenceRegistry",
    "TurnResult",
    "bootstrap_runtime",
    "event_to_public_dict",
    "run_turn",
    "select_package",
]
