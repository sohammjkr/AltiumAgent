"""Tests for the block engine.

The geometry here is the one place where a silent bug is expensive: a wrong
sign puts a footprint on the far side of the board and nothing complains.
"""

from __future__ import annotations

import math

import pytest

from altium_agent.blocks import (
    Block,
    BlockError,
    BlockLibrary,
    Instance,
    build_placement_ops,
    build_schematic_ops,
    snap_schematic_rotation,
    substitute,
    transform,
)
from altium_agent.tools.blocks_tools import allocate_designators


# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------


def test_identity_transform_changes_nothing():
    assert transform(4.2, -1.8, 90) == (4.2, -1.8, 90.0)


def test_rotation_90_is_counter_clockwise():
    dx, dy, rot = transform(10.0, 0.0, 0.0, instance_rotation=90)
    assert dx == pytest.approx(0.0, abs=1e-9)
    assert dy == pytest.approx(10.0)
    assert rot == pytest.approx(90.0)


def test_rotation_180_inverts_both_axes():
    dx, dy, rot = transform(3.0, 4.0, 0.0, instance_rotation=180)
    assert dx == pytest.approx(-3.0)
    assert dy == pytest.approx(-4.0)
    assert rot == pytest.approx(180.0)


def test_rotation_preserves_distance_from_anchor():
    for angle in (0, 30, 45, 90, 137, 270):
        dx, dy, _ = transform(4.2, -1.8, 0.0, instance_rotation=angle)
        assert math.hypot(dx, dy) == pytest.approx(math.hypot(4.2, -1.8))


def test_four_90_degree_rotations_return_to_start():
    dx, dy, rot = 4.2, -1.8, 90.0
    for _ in range(4):
        dx, dy, rot = transform(dx, dy, rot, instance_rotation=90)
    assert (dx, dy) == (pytest.approx(4.2), pytest.approx(-1.8))
    assert rot % 360 == pytest.approx(90.0)


def test_bottom_side_mirrors_x_and_negates_rotation():
    dx, dy, rot = transform(4.2, 1.8, 90.0, side="bottom")
    assert dx == pytest.approx(-4.2)
    assert dy == pytest.approx(1.8)
    assert rot == pytest.approx(270.0)      # -90 normalised


def test_bottom_side_preserves_relative_distances():
    """Mirroring must not distort the cluster, only flip it."""
    a = transform(0.0, 0.0, 0.0, side="bottom")
    b = transform(4.2, 1.8, 0.0, side="bottom")
    assert math.dist(a[:2], b[:2]) == pytest.approx(math.dist((0.0, 0.0), (4.2, 1.8)))


def test_invalid_side_rejected():
    with pytest.raises(BlockError):
        transform(1.0, 1.0, 0.0, side="inner")


@pytest.mark.parametrize(
    "raw,expected",
    [(0, 0), (89, 90), (90, 90), (135, 180), (180, 180), (271, 270), (360, 0), (-90, 270)],
)
def test_schematic_rotation_snaps_to_orthogonal(raw, expected):
    assert snap_schematic_rotation(raw) == expected


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------


def _minimal(**overrides):
    base = {
        "name": "t",
        "schematic": {
            "components": [
                {"ref": "A", "library": "L", "design_item_id": "D", "designator_prefix": "R"}
            ]
        },
    }
    base.update(overrides)
    return base


def test_duplicate_refs_rejected():
    definition = _minimal()
    definition["schematic"]["components"].append(
        {"ref": "A", "library": "L", "design_item_id": "D"}
    )
    with pytest.raises(BlockError, match="duplicate refs"):
        Block.from_dict(definition)


def test_placement_referencing_unknown_ref_rejected():
    definition = _minimal(
        placement={"anchor": "A", "components": [{"ref": "GHOST", "dx_mm": 1.0}]}
    )
    with pytest.raises(BlockError, match="unknown ref"):
        Block.from_dict(definition)


def test_anchor_must_be_a_component():
    definition = _minimal(
        placement={"anchor": "NOPE", "components": [{"ref": "A", "dx_mm": 0.0}]}
    )
    with pytest.raises(BlockError, match="anchor"):
        Block.from_dict(definition)


def test_net_referencing_unknown_ref_rejected():
    definition = _minimal()
    definition["schematic"]["nets"] = [{"name": "N", "pins": ["GHOST.1"]}]
    with pytest.raises(BlockError, match="unknown ref"):
        Block.from_dict(definition)


def test_missing_required_component_field_rejected():
    definition = _minimal()
    del definition["schematic"]["components"][0]["library"]
    with pytest.raises(BlockError, match="library"):
        Block.from_dict(definition)


# --------------------------------------------------------------------------
# Parameters
# --------------------------------------------------------------------------


def test_substitute_replaces_placeholders():
    assert substitute("{r_gate}", {"r_gate": "22R"}) == "22R"


def test_substitute_rejects_unknown_placeholder():
    """A blank value would silently place an unmarked part."""
    with pytest.raises(BlockError, match="Unknown parameter"):
        substitute("{mystery}", {"r_gate": "22R"})


def test_resolve_parameters_rejects_unknown_override(example_block):
    with pytest.raises(BlockError, match="no parameter"):
        example_block.resolve_parameters({"not_a_param": "1"})


def test_resolve_parameters_applies_defaults_then_overrides(example_block):
    resolved = example_block.resolve_parameters({"r_gate": "22R"})
    assert resolved["r_gate"] == "22R"
    assert resolved["c_boot"] == "100n"      # untouched default


# --------------------------------------------------------------------------
# Designator allocation
# --------------------------------------------------------------------------


def test_allocation_numbers_sequentially_per_prefix(example_block):
    assigned = allocate_designators(example_block, start={"U": 3, "R": 14, "C": 7, "D": 2})
    assert assigned["U_DRV"] == "U3"
    assert assigned["R_G_H"] == "R14"
    assert assigned["R_G_L"] == "R15"
    assert assigned["C_BOOT"] == "C7"
    assert assigned["C_DEC"] == "C8"
    assert assigned["D_BOOT"] == "D2"


def test_allocation_is_unique(example_block):
    assigned = allocate_designators(example_block, start={"U": 1, "R": 1, "C": 1, "D": 1})
    assert len(set(assigned.values())) == len(assigned)


def test_allocation_honours_overrides_and_avoids_collision(example_block):
    assigned = allocate_designators(
        example_block,
        start={"U": 1, "R": 1, "C": 1, "D": 1},
        overrides={"R_G_L": "R1"},
    )
    assert assigned["R_G_L"] == "R1"
    assert assigned["R_G_H"] != "R1"         # the override is not handed out twice


def test_allocation_without_a_prefix_fails_loudly(example_block):
    """Better to stop than to invent a designator and misplace a part."""
    with pytest.raises(BlockError, match="designator prefix"):
        allocate_designators(example_block, start={"U": 1})


# --------------------------------------------------------------------------
# Op building
# --------------------------------------------------------------------------


def _instance(block, **overrides):
    kwargs = {
        "block": block.name,
        "instance_id": "inst_U",
        "designators": allocate_designators(block, start={"U": 3, "R": 14, "C": 7, "D": 2}),
        "anchor_mm": (50.0, 40.0),
        "net_suffix": "_U",
    }
    kwargs.update(overrides)
    return Instance(**kwargs)


def test_schematic_ops_translate_to_the_anchor(example_block):
    instance = _instance(example_block)
    ops = build_schematic_ops(
        example_block, instance, params=example_block.resolve_parameters(), anchor_mm=(100.0, 80.0)
    )
    place = [o for o in ops if o.op == "sch.place_component"]
    driver = next(o for o in place if o.args["designator"] == "U3")
    assert (driver.args["x_mm"], driver.args["y_mm"]) == (100.0, 80.0)

    gate_r = next(o for o in place if o.args["designator"] == "R14")
    assert (gate_r.args["x_mm"], gate_r.args["y_mm"]) == (130.0, 90.0)


def test_schematic_ops_substitute_parameters(example_block):
    instance = _instance(example_block)
    ops = build_schematic_ops(
        example_block,
        instance,
        params=example_block.resolve_parameters({"r_gate": "22R"}),
        anchor_mm=(0.0, 0.0),
    )
    gate_r = next(
        o for o in ops if o.op == "sch.place_component" and o.args["designator"] == "R14"
    )
    assert gate_r.args["parameters"]["Value"] == "22R"


def test_internal_nets_get_the_instance_suffix(example_block):
    instance = _instance(example_block)
    ops = build_schematic_ops(
        example_block, instance, params=example_block.resolve_parameters(), anchor_mm=(0.0, 0.0)
    )
    names = {o.args["net_name"] for o in ops if o.op == "sch.set_net_name"}
    assert names == {"VB_U", "HO_U", "LO_U"}


def test_interface_nets_are_left_alone(example_block):
    """Interface nets belong to the surrounding design, not the instance."""
    instance = _instance(example_block)
    ops = build_schematic_ops(
        example_block, instance, params=example_block.resolve_parameters(), anchor_mm=(0.0, 0.0)
    )
    names = {o.args["net_name"] for o in ops if o.op == "sch.set_net_name"}
    assert not any(n.startswith(("VCC", "GND", "PWM", "GATE", "SW")) for n in names)


def test_net_pins_are_mapped_to_real_designators(example_block):
    instance = _instance(example_block)
    ops = build_schematic_ops(
        example_block, instance, params=example_block.resolve_parameters(), anchor_mm=(0.0, 0.0)
    )
    ho = next(o for o in ops if o.op == "sch.set_net_name" and o.args["net_name"] == "HO_U")
    assert set(ho.args["pins"]) == {"U3.7", "R14.1"}


def test_placement_ops_move_rather_than_create(example_block):
    instance = _instance(example_block)
    ops = build_placement_ops(example_block, instance, anchor_mm=(62.0, 40.0))
    assert {o.op for o in ops} == {"pcb.move_component"}


def test_placement_ops_apply_anchor_and_rotation(example_block):
    instance = _instance(example_block, rotation=90.0)
    ops = build_placement_ops(example_block, instance, anchor_mm=(62.0, 40.0))
    driver = next(o for o in ops if o.args["designator"] == "U3")
    assert (driver.args["x_mm"], driver.args["y_mm"]) == (62.0, 40.0)

    # R_G_H sits at (+4.2, +1.8); rotated 90 CCW that becomes (-1.8, +4.2).
    gate_r = next(o for o in ops if o.args["designator"] == "R14")
    assert gate_r.args["x_mm"] == pytest.approx(62.0 - 1.8)
    assert gate_r.args["y_mm"] == pytest.approx(40.0 + 4.2)


def test_bottom_instance_flips_every_component_layer(example_block):
    instance = _instance(example_block, side="bottom")
    ops = build_placement_ops(example_block, instance, anchor_mm=(0.0, 0.0))
    assert {o.args["layer"] for o in ops} == {"bottom"}


def test_placement_without_captured_placement_fails_usefully():
    block = Block.from_dict(_minimal())
    instance = Instance(block="t", instance_id="i", designators={"A": "R1"})
    with pytest.raises(BlockError, match="capture_placement"):
        build_placement_ops(block, instance, anchor_mm=(0.0, 0.0))


def test_missing_designator_fails_rather_than_placing_wrong(example_block):
    instance = _instance(example_block, designators={"U_DRV": "U3"})
    with pytest.raises(BlockError, match="No designator allocated"):
        build_placement_ops(example_block, instance, anchor_mm=(0.0, 0.0))


# --------------------------------------------------------------------------
# Library round trip
# --------------------------------------------------------------------------


def test_block_survives_a_save_load_round_trip(example_block, tmp_path):
    library = BlockLibrary(tmp_path)
    library.save(example_block)
    reloaded = library.get(example_block.name)
    assert reloaded.to_dict() == example_block.to_dict()


def test_unknown_block_error_lists_what_is_available(example_block, tmp_path):
    library = BlockLibrary(tmp_path)
    library.save(example_block)
    with pytest.raises(BlockError, match="gate_drive_hb"):
        library.get("no_such_block")
