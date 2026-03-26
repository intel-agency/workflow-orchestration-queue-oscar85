I completely refactored the orchestration-agent prompt state machine. Two biggesdt cnages:
1. broken down into single dynamic workflow match clause prompts
2. state change is driven directly from within the prompt file, by applying "orchestration:epic-XXX" labels to match the next step in the sequence.

The project-setup workflow will still be initiaited by the `trigger-project-setup.sh` from the end of `create-repo-from-plan-docs.ps1` script,

but I am still trying to figure out how to initiate the initial step for this sequence from the end of project-setup, i.e. after the complete implementation plan issue is created.

Also, I added all three folders to this workdpace: `worklflow_launch2`, and `agent-instructions` so we have all three releavant workspaces' worth of code right here.

Analyze in-depth for internal consistency anf any gotchas or weaknesses in the new design, or any places that could be made more robust.
