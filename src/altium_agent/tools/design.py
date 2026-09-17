"""Project and document level tools."""

from __future__ import annotations

from .base import READ, ToolSpec, obj, string

DESIGN_TOOLS = [
    ToolSpec(
        name="design_status",
        op="design.status",
        mode=READ,
        description=(
            "Report what Altium currently has open: project, documents, which one is focused, "
            "the current selection, and whether anything has unsaved changes. Call this first "
            "in almost every conversation - it tells you what the user is looking at, so you "
            "do not have to ask."
        ),
        schema=obj({}, required=[]),
    ),
    ToolSpec(
        name="design_open_document",
        op="design.open_document",
        description=(
            "Open and focus a document belonging to the current project. Use this when work "
            "needs to move between the schematic and the PCB."
        ),
        schema=obj(
            {
                "document": string(
                    "Document filename as listed by design_status, e.g. 'SH1_POWER.SchDoc'."
                )
            },
            required=["document"],
        ),
    ),
    ToolSpec(
        name="design_save",
        op="design.save",
        description=(
            "Save modified documents. Ask the user before saving unless they have already "
            "asked you to - they may want to inspect the changes and undo them first."
        ),
        schema=obj(
            {
                "document": string(
                    "Document to save. Omit to save every modified document in the project."
                )
            },
            required=[],
        ),
    ),
]
