"""Tool registry primitives.

A tool is one of two kinds:

* **bridge tool** - translates into one or more ops that Altium executes. The
  agent loop collects every bridge tool call in an assistant turn and ships
  them as a SINGLE batch, which is what keeps Altium responsive.
* **local tool** - answered entirely in Python (listing blocks, reading a block
  definition). Never touches Altium, so it costs nothing and never waits.

Tool names use underscores because the API restricts tool names to
[a-zA-Z0-9_-]; the corresponding bridge op keeps the dotted form
(`sch_place_component` -> `sch.place_component`).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Protocol

from ..protocol import Op


class ToolContext(Protocol):
    """What a tool builder is allowed to reach for."""

    @property
    def blocks(self) -> Any: ...

    @property
    def instances(self) -> Any: ...

    @property
    def cfg(self) -> Any: ...


BuildFn = Callable[[dict[str, Any], ToolContext], list[Op]]
LocalFn = Callable[[dict[str, Any], ToolContext], dict[str, Any]]

READ = "read"
WRITE = "write"


def is_closed_schema(schema: dict[str, Any]) -> bool:
    """True if every object in the schema sets additionalProperties: false.

    Strict tool use requires that. A schema with a map-shaped field (component
    parameters, designator overrides) cannot satisfy it, and asking for strict
    mode anyway is a 400.
    """
    if not isinstance(schema, dict):
        return True
    if schema.get("type") == "object" and schema.get("additionalProperties") is not False:
        return False
    for key in ("properties", "$defs", "definitions"):
        for child in (schema.get(key) or {}).values():
            if not is_closed_schema(child):
                return False
    for key in ("items", "additionalProperties"):
        child = schema.get(key)
        if isinstance(child, dict) and not is_closed_schema(child):
            return False
    for key in ("anyOf", "oneOf", "allOf"):
        for child in schema.get(key) or []:
            if not is_closed_schema(child):
                return False
    return True


@dataclass(slots=True)
class ToolSpec:
    name: str
    description: str
    schema: dict[str, Any]
    op: str | None = None
    mode: str = WRITE
    build: BuildFn | None = None
    local: LocalFn | None = None
    txn_label: str | None = None

    @property
    def is_local(self) -> bool:
        return self.local is not None

    def to_api_tool(self) -> dict[str, Any]:
        """Anthropic tool definition.

        strict mode guarantees tool inputs validate against the schema, which is
        worth having when a malformed coordinate puts a component 10 metres off
        the board. It requires every object to be closed
        (additionalProperties: false), so it is enabled only for schemas that
        actually are - map-shaped inputs like component parameters cannot be.
        """
        tool: dict[str, Any] = {
            "name": self.name,
            "description": self.description,
            "input_schema": self.schema,
        }
        if is_closed_schema(self.schema):
            tool["strict"] = True
        return tool

    def build_ops(self, tool_use_id: str, args: dict[str, Any], ctx: ToolContext) -> list[Op]:
        if self.build is not None:
            ops = self.build(args, ctx)
        else:
            if self.op is None:
                raise ValueError(f"Tool {self.name} has neither an op nor a builder")
            ops = [Op(id="0", op=self.op, args=dict(args))]

        # Re-key so results can be attributed back to the originating tool call.
        for index, op in enumerate(ops):
            op.id = f"{tool_use_id}#{index}"
        return ops


def obj(
    properties: dict[str, Any],
    required: list[str] | None = None,
) -> dict[str, Any]:
    """Build a strict-mode-compatible object schema.

    strict=True requires additionalProperties:false and an explicit `required`
    list, so this helper makes it impossible to forget either.
    """
    return {
        "type": "object",
        "properties": properties,
        "required": required if required is not None else list(properties),
        "additionalProperties": False,
    }


# Field shorthands, so the schemas below stay readable.

def num(description: str) -> dict[str, Any]:
    return {"type": "number", "description": description}


def string(description: str, **extra: Any) -> dict[str, Any]:
    return {"type": "string", "description": description, **extra}


def integer(description: str, **extra: Any) -> dict[str, Any]:
    return {"type": "integer", "description": description, **extra}


def boolean(description: str) -> dict[str, Any]:
    return {"type": "boolean", "description": description}


def array(item: dict[str, Any], description: str) -> dict[str, Any]:
    return {"type": "array", "items": item, "description": description}


X_MM = num("X position in millimetres, in the document's own coordinate system.")
Y_MM = num("Y position in millimetres, in the document's own coordinate system.")
POINT_MM = {
    "type": "array",
    "items": {"type": "number"},
    "minItems": 2,
    "maxItems": 2,
    "description": "An [x, y] point in millimetres.",
}


class Registry:
    """Name -> ToolSpec, with the API tool list derived from it."""

    def __init__(self, specs: list[ToolSpec] | None = None) -> None:
        self._specs: dict[str, ToolSpec] = {}
        for spec in specs or []:
            self.add(spec)

    def add(self, spec: ToolSpec) -> None:
        if spec.name in self._specs:
            raise ValueError(f"Duplicate tool name {spec.name}")
        self._specs[spec.name] = spec

    def extend(self, specs: list[ToolSpec]) -> None:
        for spec in specs:
            self.add(spec)

    def get(self, name: str) -> ToolSpec:
        if name not in self._specs:
            raise KeyError(f"Unknown tool {name!r}")
        return self._specs[name]

    def __contains__(self, name: object) -> bool:
        return name in self._specs

    def __len__(self) -> int:
        return len(self._specs)

    def names(self) -> list[str]:
        return sorted(self._specs)

    def api_tools(self, *, read_only: bool = False) -> list[dict[str, Any]]:
        specs = self._specs.values()
        if read_only:
            specs = [s for s in specs if s.mode == READ or s.is_local]
        return [s.to_api_tool() for s in sorted(specs, key=lambda s: s.name)]

    def writes(self) -> list[str]:
        return sorted(n for n, s in self._specs.items() if s.mode == WRITE and not s.is_local)
