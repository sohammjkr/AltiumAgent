"""Headless wake: ask an already-running Altium to drain the queue once.

Altium is single-instance, so launching X2.EXE with a -R process argument is
expected to dispatch into the running process rather than starting a second
one. That behaviour is NOT verified on the Develop build on this machine -
see docs/altium-api.md. Everything here degrades to a clear error rather than
hanging if it turns out not to work.

The interactive path (agent panel open in Altium) never needs this.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)

SCRIPT_PROJECT = Path("altium") / "AltiumAgent.PrjScr"


def build_command(altium_exe: Path, script_project: Path, procedure: str) -> list[str]:
    """Build the RunScript dispatch argv.

    Altium's process syntax is:
        -RScriptingSystem:RunScript(ProjectName="<abs>"|ProcedureName="<proc>")
    The pipe separates parameters and must survive shell quoting, which is why
    this is passed as a single argv element with shell=False.
    """
    arg = (
        "-RScriptingSystem:RunScript("
        f'ProjectName="{script_project.resolve()}"|'
        f'ProcedureName="{procedure}")'
    )
    return [str(altium_exe), arg]


def wake_altium(
    altium_exe: Path,
    script_project: Path = SCRIPT_PROJECT,
    procedure: str = "DrainOnce",
    timeout_s: int = 30,
) -> tuple[bool, str]:
    """Fire one headless drain. Returns (dispatched, message).

    A true `dispatched` only means the command was accepted - it does not mean
    the batch ran. Confirm that by waiting on the result file, as bridge.py does.
    """
    if not altium_exe.exists():
        return False, f"Altium executable not found: {altium_exe}"
    if not script_project.exists():
        return False, f"Script project not found: {script_project}"

    cmd = build_command(altium_exe, script_project, procedure)
    log.debug("wake: %s", cmd)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        # A hang here usually means Altium was not running and this call is
        # booting a fresh instance, which takes far longer than timeout_s.
        return False, (
            "Wake command did not return. Altium is probably not running - "
            "start it and open the agent panel instead."
        )
    except OSError as exc:
        return False, f"Could not launch Altium: {exc}"

    if proc.returncode != 0:
        return False, f"Altium returned {proc.returncode}: {proc.stderr.strip()[:400]}"
    return True, "Wake dispatched"
