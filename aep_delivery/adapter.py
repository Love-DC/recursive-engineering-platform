"""Typed capability contract and deterministic GitHub provider fake for Stage 3."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import hashlib
from typing import Any


class CapabilityState(str, Enum):
    SUPPORTED = "supported"
    UNSUPPORTED = "unsupported"
    UNAVAILABLE = "unavailable"


class UnsupportedOperation(RuntimeError):
    """The adapter manifest explicitly rejects an operation."""


class LostProviderResponse(ConnectionError):
    """The fake provider committed a side effect but the caller lost its response."""


@dataclass(frozen=True)
class Capability:
    status: CapabilityState
    tools: tuple[str, ...]
    notes: str
    identity: str | None = None
    independent_principal: CapabilityState | None = None


@dataclass(frozen=True)
class ProviderObservation:
    found: bool
    authoritative: bool
    external_object_type: str | None = None
    external_id: str | None = None
    revision: str | None = None
    pull_request_number: int | None = None
    pull_request_url: str | None = None
    pr_head_sha: str | None = None
    merge_sha: str | None = None

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "found": self.found,
            "authoritative": self.authoritative,
        }
        for key, value in (
            ("external_object_type", self.external_object_type),
            ("external_id", self.external_id),
            ("revision", self.revision),
            ("pull_request_number", self.pull_request_number),
            ("pull_request_url", self.pull_request_url),
            ("pr_head_sha", self.pr_head_sha),
            ("merge_sha", self.merge_sha),
        ):
            if value is not None:
                result[key] = value
        return result


class GitHubCapabilityManifest:
    REQUIRED = {
        "branch_ref",
        "pull_request",
        "process_review",
        "native_approval",
        "merge",
        "ci_lookup",
        "post_merge_verification",
        "deployment",
    }

    def __init__(self, data: dict[str, Any]) -> None:
        self.data = data
        self._validate()

    def _validate(self) -> None:
        if self.data.get("schema_version") != 1:
            raise ValueError("unsupported adapter manifest schema_version")
        operations = self.data.get("operations")
        if not isinstance(operations, dict) or set(operations) != self.REQUIRED:
            raise ValueError("manifest must declare exactly the required delivery operations")
        for name, item in operations.items():
            if not isinstance(item, dict):
                raise ValueError(f"capability {name} must be an object")
            try:
                CapabilityState(item["status"])
            except (KeyError, ValueError) as exc:
                raise ValueError(f"invalid capability status for {name}") from exc
            if not isinstance(item.get("tools"), list):
                raise ValueError(f"capability {name} must declare its tool surface")
            if not isinstance(item.get("notes"), str) or not item["notes"].strip():
                raise ValueError(f"capability {name} must explain its boundary")
        native = operations["native_approval"]
        process = operations["process_review"]
        if native.get("independent_principal") != CapabilityState.UNAVAILABLE.value:
            raise ValueError("separate native approver principal is unavailable in this session")
        if process.get("identity") != "same_authenticated_principal":
            raise ValueError("process review must disclose the shared authenticated principal")

    def capability(self, name: str) -> Capability:
        try:
            item = self.data["operations"][name]
        except KeyError as exc:
            raise UnsupportedOperation(f"unknown capability: {name}") from exc
        state = CapabilityState(item["status"])
        if state is not CapabilityState.SUPPORTED:
            raise UnsupportedOperation(f"{name} is {state.value}")
        independent = item.get("independent_principal")
        return Capability(
            status=state,
            tools=tuple(item["tools"]),
            notes=item["notes"],
            identity=item.get("identity"),
            independent_principal=(
                CapabilityState(independent) if independent is not None else None
            ),
        )

    def require(self, name: str) -> Capability:
        return self.capability(name)


class FakeGitHubProvider:
    """Deterministic provider double with a response-loss fault after side effect."""

    def __init__(self) -> None:
        self._objects: dict[str, tuple[str, dict[str, Any]]] = {}
        self.calls: dict[str, int] = {}
        self.lose_next_response = False
        self._next_pr_number = 700

    @staticmethod
    def _sha(value: str) -> str:
        return hashlib.sha1(value.encode("utf-8")).hexdigest()

    def execute(
        self, idempotency_key: str, operation_type: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        payload_hash = hashlib.sha256(
            __import__("json").dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        existing = self._objects.get(idempotency_key)
        if existing is not None:
            existing_hash, response = existing
            if existing_hash != payload_hash:
                raise ValueError("fake provider idempotency key payload conflict")
            return dict(response)

        self.calls[idempotency_key] = self.calls.get(idempotency_key, 0) + 1
        external_id = f"fake-{operation_type}-{len(self._objects) + 1}"
        response: dict[str, Any] = {
            "found": True,
            "authoritative": True,
            "external_object_type": "pull_request" if "pull_request" in operation_type or operation_type == "merge" else "ref",
            "external_id": external_id,
            "revision": self._sha(idempotency_key + payload_hash),
        }
        if operation_type == "pull_request_create":
            self._next_pr_number += 1
            response.update({
                "pull_request_number": self._next_pr_number,
                "pull_request_url": f"https://github.com/fake/repo/pull/{self._next_pr_number}",
                "pr_head_sha": self._sha("pr-head:" + idempotency_key),
            })
        if operation_type == "merge":
            response["merge_sha"] = self._sha("merge:" + idempotency_key)
        self._objects[idempotency_key] = (payload_hash, dict(response))
        if self.lose_next_response:
            self.lose_next_response = False
            raise LostProviderResponse("provider completed the side effect; response was lost")
        return response

    def observe(self, idempotency_key: str) -> dict[str, Any]:
        existing = self._objects.get(idempotency_key)
        if existing is None:
            return {"found": False, "authoritative": True}
        return dict(existing[1])
