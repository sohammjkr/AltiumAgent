"""Command line entry points."""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from .blocks import BlockLibrary
from .bridge import AltiumBridge, FakeBridge
from .config import Config, load_config
from .protocol import read_json
from .tools import build_registry

LOG_FORMAT = "%(asctime)s  %(levelname)-7s %(name)s  %(message)s"


def _setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format=LOG_FORMAT,
        datefmt="%H:%M:%S",
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpx2").setLevel(logging.WARNING)


def _tick(ok: bool) -> str:
    return "PASS" if ok else "FAIL"


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def cmd_doctor(args: argparse.Namespace, cfg: Config) -> int:
    print("Altium Agent - environment check\n")
    problems = 0

    checks: list[tuple[str, bool, str]] = []

    has_key = bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))
    checks.append((
        "Anthropic credentials",
        has_key,
        "set ANTHROPIC_API_KEY in .env, or run `ant auth login`",
    ))

    checks.append((
        f"Altium executable ({cfg.altium_exe})",
        cfg.altium_exe.exists(),
        "set ALTIUM_EXE in .env",
    ))

    script_project = Path("altium") / "AltiumAgent.PrjScr"
    checks.append((
        f"Script project ({script_project})",
        script_project.exists(),
        "run from the repository root",
    ))

    try:
        cfg.ensure_dirs()
        writable = True
    except OSError:
        writable = False
    checks.append((
        f"Bridge workdir ({cfg.workdir})",
        writable,
        "set ALTIUM_AGENT_WORKDIR to a writable local path",
    ))

    bridge = AltiumBridge(cfg) if writable else None
    state = bridge.read_state() if bridge else {}
    checks.append((
        "Bridge has reported state",
        bool(state),
        "open altium/AltiumAgent.PrjScr in Altium and run AgentPanel",
    ))

    for label, ok, hint in checks:
        print(f"  [{_tick(ok)}] {label}")
        if not ok:
            print(f"         -> {hint}")
            problems += 1

    sync_warning = cfg.warn_if_synced()
    if sync_warning:
        print(f"\n  [WARN] {sync_warning}")

    registry = build_registry()
    blocks = BlockLibrary(cfg.blocks_dir)
    print(f"\n  {len(registry)} tools registered, {len(blocks.names())} blocks defined")
    print(f"  model={cfg.model} effort={cfg.effort}")

    if state:
        print(f"  bridge: polling={state.get('polling')} last_tick={state.get('last_tick')}")

    print()
    if problems:
        print(f"{problems} problem(s) to fix before the agent will work end to end.")
    else:
        print("Ready.")
    return 1 if problems else 0


def cmd_probe(args: argparse.Namespace, cfg: Config) -> int:
    """Read the capability probe written by the in-Altium Probe.pas."""
    path = cfg.workdir / "probe.json"
    if not path.exists():
        print(f"No probe results at {path}\n")
        print("In Altium: open altium/AltiumAgent.PrjScr, open Probe.pas, run Probe_Main.")
        return 1

    try:
        data = read_json(path)
    except ValueError as exc:
        print(f"probe.json is not valid JSON: {exc}")
        return 1

    checks = data.get("checks", {})
    print(f"Probe from Altium build: {data.get('altium_build', 'unknown')}")
    print(f"Written: {data.get('written', 'unknown')}\n")

    failed = 0
    for name in sorted(checks):
        entry = checks[name]
        ok = bool(entry.get("ok")) if isinstance(entry, dict) else bool(entry)
        detail = entry.get("detail", "") if isinstance(entry, dict) else ""
        print(f"  [{_tick(ok)}] {name}{'  - ' + detail if detail else ''}")
        if not ok:
            failed += 1

    print()
    if failed:
        print(f"{failed} capability check(s) failed. See docs/altium-api.md for what each means.")
    else:
        print("All probed capabilities available.")
    return 1 if failed else 0


def cmd_serve(args: argparse.Namespace, cfg: Config) -> int:
    from .daemon import build_daemon

    daemon = build_daemon(cfg)
    daemon.run(once=args.once)
    return 0


def cmd_chat(args: argparse.Namespace, cfg: Config) -> int:
    """Terminal chat. Useful for exercising the agent before the panel works."""
    from .agent import DesignAgent

    bridge: AltiumBridge = FakeBridge(cfg) if args.dry_run else AltiumBridge(cfg)
    agent = DesignAgent(cfg, bridge)

    if args.dry_run:
        print("Dry run: Altium operations are simulated, nothing is changed.\n")

    print("Altium Agent. Ctrl-C or an empty line to quit.\n")
    while True:
        try:
            text = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not text:
            return 0

        result = agent.run_turn(
            text,
            on_progress=lambda kind, detail: (
                print(f"  ... {detail}") if kind == "tool" else None
            ),
        )
        print(f"\nagent> {result.text}\n")
        if result.status != "done":
            print(f"[{result.status}]\n")


def cmd_blocks(args: argparse.Namespace, cfg: Config) -> int:
    library = BlockLibrary(cfg.blocks_dir)
    summaries = library.summaries()
    if not summaries:
        print(f"No blocks in {cfg.blocks_dir}. See docs/blocks.md for how to capture one.")
        return 0
    for entry in summaries:
        if "error" in entry:
            print(f"  {entry['name']}: INVALID - {entry['error']}")
            continue
        placement = "with placement" if entry["has_placement"] else "schematic only"
        print(f"  {entry['name']:<24} {entry['components']:>3} parts  {placement}")
        if entry["title"]:
            print(f"  {'':<24} {entry['title']}")
    return 0


def cmd_tools(args: argparse.Namespace, cfg: Config) -> int:
    registry = build_registry()
    tools = registry.api_tools(read_only=args.read_only)
    if args.json:
        print(json.dumps(tools, indent=2))
        return 0
    for tool in tools:
        strict = " (strict)" if tool.get("strict") else ""
        print(f"  {tool['name']}{strict}")
    print(f"\n{len(tools)} tools")
    return 0


def cmd_wake(args: argparse.Namespace, cfg: Config) -> int:
    from .wake import build_command, wake_altium

    project = Path("altium") / "AltiumAgent.PrjScr"
    print("Command:")
    print(" ", build_command(cfg.altium_exe, project, args.procedure))
    print()
    ok, message = wake_altium(cfg.altium_exe, project, args.procedure)
    print(f"[{_tick(ok)}] {message}")
    if ok:
        print("\nNote: this only means the command was accepted. Check Altium actually ran it.")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# Parser
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="altium-agent",
        description="Conversational PCB design agent driving Altium Designer.",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    parser.add_argument("--workdir", help="override the bridge working directory")
    parser.add_argument("--model", help="override the model id")
    parser.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max"])
    parser.add_argument(
        "--read-only",
        action="store_true",
        help="refuse every operation that would modify the design",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("doctor", help="check the environment is set up correctly")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("probe", help="read the in-Altium capability probe results")
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("serve", help="run the daemon that backs the Altium panel")
    p.add_argument("--once", action="store_true", help="handle pending turns then exit")
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("chat", help="chat in the terminal instead of the Altium panel")
    p.add_argument("--dry-run", action="store_true", help="simulate Altium, change nothing")
    p.set_defaults(func=cmd_chat)

    p = sub.add_parser("blocks", help="list reusable circuit blocks")
    p.set_defaults(func=cmd_blocks)

    p = sub.add_parser("tools", help="list the agent's tool surface")
    p.add_argument("--json", action="store_true", help="emit the full tool definitions")
    p.set_defaults(func=cmd_tools)

    p = sub.add_parser("wake", help="test the headless Altium wake")
    p.add_argument("--procedure", default="DrainOnce")
    p.set_defaults(func=cmd_wake)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    _setup_logging(args.verbose)

    cfg = load_config(
        workdir=Path(args.workdir) if args.workdir else None,
        model=args.model,
        effort=args.effort,
        read_only=args.read_only or None,
    )

    try:
        return args.func(args, cfg)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
