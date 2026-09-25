"""Headless wake: ask an already-running Altium to drain the queue once.

VERIFIED BEHAVIOUR (Altium Designer Develop build, 2026-09-17)
-------------------------------------------------------------
Launching X2.EXE with a -R process argument while Altium is already running
DOES dispatch into the running instance. It does not start a second one - the
new process blocks on the startup mutex and exits.

Two things were learned the hard way and are encoded below:

1. **The procedure name must be document-qualified** ("Probe.pas>Probe_Main",
   not "Probe_Main"). An unqualified name makes Altium pop its "Select Item To
   Run" dialog and sit there waiting for a human, which looks exactly like a
   hang from the outside.

2. **Never wait on the launcher process.** The original implementation used
   subprocess.run(timeout=30), and subprocess.run KILLS the child on timeout -
   so the 30s limit was killing the hand-off it was supposed to be waiting
   for. The launcher is fire-and-forget; the meaningful signal is the result
   file appearing, which bridge.py already waits on.

The interactive path (agent panel open in Altium) never needs any of this.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)

SCRIPT_PROJECT = Path("altium") / "AltiumAgent.PrjScr"

# Which script document each entry point lives in. Altium needs the qualified
# "Document>Procedure" form or it prompts the user to choose.
PROCEDURE_DOCUMENTS = {
    "DrainOnce": "Bridge.pas",
    "Probe_Main": "Probe.pas",
    "RunAgentPanel": "AgentPanel.pas",
}


def qualify(procedure: str) -> str:
    """Return the Document>Procedure form Altium needs to run without prompting."""
    if ">" in procedure:
        return procedure
    document = PROCEDURE_DOCUMENTS.get(procedure)
    return f"{document}>{procedure}" if document else procedure


def build_command(altium_exe: Path, script_project: Path, procedure: str) -> list[str]:
    """Build the RunScript dispatch argv.

    Altium's process syntax is:
        -RScriptingSystem:RunScript(ProjectName="<abs>"|ProcedureName="<doc>><proc>")
    The pipe separates parameters and must survive shell quoting, which is why
    this is passed as a single argv element with shell=False.
    """
    arg = (
        "-RScriptingSystem:RunScript("
        f'ProjectName="{script_project.resolve()}"|'
        f'ProcedureName="{qualify(procedure)}")'
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
