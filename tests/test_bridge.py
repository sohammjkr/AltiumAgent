"""Tests for the bridge transport and the tool registry."""

from __future__ import annotations

import json
import threading
import time

import pytest

from altium_agent.bridge import AltiumBridge, FakeBridge
from altium_agent.protocol import (
    BridgeError,
    BridgeTimeout,
    Op,
    read_json,
    write_atomic,
)
from altium_agent.tools import build_registry
from altium_agent.tools.base import is_closed_schema


# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------


def test_atomic_write_leaves_no_temp_files(tmp_path):
    target = tmp_path / "out.json"
    write_atomic(target, {"hello": "world"})
    assert read_json(target) == {"hello": "world"}
    assert list(tmp_path.glob("*.tmp")) == []


def test_atomic_write_creates_missing_parents(tmp_path):
    target = tmp_path / "deep" / "nested" / "out.json"
    write_atomic(target, {"ok": True})
    assert target.exists()


def test_submit_writes_a_single_batch_for_many_ops(cfg):
    """One batch per turn is the whole point - it is one Altium wake, not N."""
    bridge = AltiumBridge(cfg)
    ops = [Op(id=f"op{i}", op="sch.place_component", args={"designator": f"R{i}"})
           for i in range(12)]

    def respond():
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            pending = list(cfg.cmd_in.glob("b*.json"))
            if pending:
                batch = read_json(pending[0])
                write_atomic(
                    cfg.cmd_out / f"{batch['batch']}.json",
                    {
                        "batch": batch["batch"],
                        "ok": True,
                        "results": [{"id": o["id"], "ok": True, "data": {}}
                                    for o in batch["ops"]],
                    },
                )
                return
            time.sleep(0.01)

    responder = threading.Thread(target=respond)
    responder.start()
    try:
        result = bridge.submit(ops, turn="t1", txn_label="Place twelve parts")
    finally:
        responder.join()

    assert result.ok
    assert len(result.results) == 12


def test_submit_rejects_an_oversized_batch(cfg):
    """A huge batch blocks Altium's UI thread for too long."""
    cfg.max_batch_ops = 4
    bridge = AltiumBridge(cfg)
    ops = [Op(id=f"op{i}", op="design.status") for i in range(5)]
    with pytest.raises(BridgeError, match="max_batch_ops"):
        bridge.submit(ops, turn="t1", txn_label="too many")


def test_submit_times_out_with_an_actionable_message(cfg):
    cfg.batch_timeout_s = 1
    bridge = AltiumBridge(cfg)
    with pytest.raises(BridgeTimeout, match="agent panel"):
        bridge.submit([Op(id="op0", op="design.status")], turn="t1", txn_label="x")


def test_empty_batch_is_a_no_op(cfg):
    bridge = AltiumBridge(cfg)
    result = bridge.submit([], turn="t1", txn_label="nothing")
    assert result.ok
    assert result.results == []


def test_batch_ids_resume_after_a_restart(cfg):
    first = AltiumBridge(cfg)
    write_atomic(cfg.cmd_in / "b000007.json", {"batch": "b000007", "ops": []})
    second = AltiumBridge(cfg)
    assert second._new_batch_id() == "b000008"
    assert first is not second


def test_fake_bridge_records_without_touching_altium(cfg):
    bridge = FakeBridge(cfg)
    result = bridge.submit(
        [Op(id="op0", op="design.status")], turn="t1", txn_label="status"
    )
    assert result.ok
    assert len(bridge.submitted) == 1
    assert bridge.submitted[0].txn_label == "status"


# --------------------------------------------------------------------------
# Tool registry
# --------------------------------------------------------------------------


def test_registry_builds_and_is_not_empty():
    assert len(build_registry()) > 20


def test_tool_names_are_api_legal():
    """The API restricts tool names to [a-zA-Z0-9_-]; dots are not allowed."""
    import re

    pattern = re.compile(r"^[a-zA-Z0-9_-]{1,128}$")
    for name in build_registry().names():
        assert pattern.match(name), f"illegal tool name: {name}"


def test_every_tool_has_a_description_and_schema():
    for tool in build_registry().api_tools():
        assert tool["description"].strip()
        assert tool["input_schema"]["type"] == "object"


def test_strict_is_only_claimed_for_closed_schemas():
    """Claiming strict on a map-shaped schema is a 400 from the API."""
    for tool in build_registry().api_tools():
        if tool.get("strict"):
            assert is_closed_schema(tool["input_schema"])


def test_read_only_mode_hides_every_write_tool():
    registry = build_registry()
    names = {t["name"] for t in registry.api_tools(read_only=True)}
    assert "sch_place_component" not in names
    assert "pcb_move_component" not in names
    assert "sch_list_components" in names
    assert "design_status" in names


def test_every_bridge_tool_has_an_op_or_builder():
    registry = build_registry()
    for name in registry.names():
        spec = registry.get(name)
        assert spec.is_local or spec.op or spec.build, f"{name} cannot be executed"


def test_tool_definitions_are_json_serialisable():
    json.dumps(build_registry().api_tools())


def test_op_ids_are_rekeyed_to_the_tool_use_id(cfg):
    """Results are attributed back to a tool call by this id prefix."""
    from altium_agent.agent import Context
    from altium_agent.blocks import BlockLibrary, InstanceStore

    ctx = Context(
        cfg=cfg,
        blocks=BlockLibrary(cfg.blocks_dir),
        instances=InstanceStore(cfg.instances_file),
    )
    spec = build_registry().get("sch_place_component")
    ops = spec.build_ops("toolu_abc123", {"designator": "R1"}, ctx)
    assert [o.id for o in ops] == ["toolu_abc123#0"]
