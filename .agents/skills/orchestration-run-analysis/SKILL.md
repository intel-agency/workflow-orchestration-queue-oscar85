---
name: orchestration-run-analysis
description: >-
  Investigate orchestration workflow runs, issues, PRs, and milestones from a
  deployed template repository. Gathers evidence from GitHub Actions logs,
  event routing, label state transitions, and agent trace artifacts to produce
  a structured markdown post-mortem report.
  Use when: analyzing why an orchestrator run failed or stalled, auditing
  completed workflow sequences, comparing expected vs actual event routing,
  creating run reports for deployed template instances.
license: MIT
compatibility: copilot, opencode
metadata:
  audience: orchestrator-operators
  workflow: post-mortem-analysis
---

## What I Do

- Map the complete timeline of GitHub Actions workflow runs for a deployed template repo
- Trace orchestrator-agent event routing (which clause matched, which fell to default)
- Identify title/label mismatches that cause clause routing failures
- Audit issue, PR, milestone, and project board state against expected outcomes
- Collect trace artifact metadata and external reviewer activity
- Produce a structured markdown report with root cause analysis and recommendations

## When to Use Me

Use this skill when:

- A deployed template repository (generated from `ai-new-workflow-app-template`) has completed one or more orchestrator runs and you need to understand what happened
- An orchestration sequence stalled or produced fewer issues/PRs/epics than expected
- You need a formal post-mortem of a workflow run for debugging or documentation
- Comparing expected orchestrator behavior against actual event data

Ask clarifying questions if the target repository URL or the specific runs to investigate are unclear.

## Workflow

### 1. Identify the Target Repository

Collect from the user:

- **Repository**: The full `owner/repo` slug (e.g. `intel-agency/workflow-orchestration-queue-zulu78-b`)
- **Time range** (optional): Which runs to focus on (default: all runs)
- **Specific concern** (optional): "Why didn't epics get created?", "Why did it stall?", etc.

### 2. Gather Evidence (Parallel)

Fetch the following data sources in parallel where possible:

#### 2a. Workflow Runs Inventory

Fetch the Actions page for the orchestrator-agent workflow:

```
https://github.com/{owner}/{repo}/actions/workflows/orchestrator-agent.yml
```

For each run, record:

| Field | Source |
|-------|--------|
| Run number | Page listing |
| Trigger event | `on: issues / workflow_run / workflow_dispatch` |
| Trigger details | Issue number, label name, action (opened/labeled) |
| Duration | Run duration |
| Result | success / skipped / failure / cancelled |
| Jobs executed | `skip-event` vs `orchestrate` |
| Artifacts | opencode-traces size |

#### 2b. Issues Inventory

Fetch all issues (open and closed):

```
https://github.com/{owner}/{repo}/issues?q=is:issue
```

For each issue, record:
- Title, number, state (open/closed)
- Labels applied
- Milestone assignment
- Comment count and commenters (especially bot accounts)
- Whether the title matches any orchestrator prompt clause

#### 2c. Pull Requests Inventory

Fetch all PRs:

```
https://github.com/{owner}/{repo}/pulls?q=is:pr
```

For each PR, record:
- Title, number, state, source branch
- Commit count and check status
- Reviewer activity (Gemini, Copilot, CodeQL, human)
- Files changed summary

#### 2d. Milestones

Fetch milestone list:

```
https://github.com/{owner}/{repo}/milestones
```

Record: name, description, open/closed issue counts, percent complete.

#### 2e. Supporting Workflows

Check the status of non-orchestrator workflows:
- `validate` — CI checks
- `CodeQL` — security analysis
- `Publish Docker` — image publishing
- `Pre-build dev container image` — devcontainer prebuild

### 3. Deep-Dive: Individual Orchestrator Runs

For each orchestrator-agent run that actually executed (not skipped):

1. **Fetch the run summary page**: `https://github.com/{owner}/{repo}/actions/runs/{run_id}`
2. **Record annotations**: warnings, notices (especially "Orchestrator skipped" or exit codes)
3. **Check which jobs ran**: `skip-event` (means filtered out) vs `orchestrate` (means event was processed)
4. **Note trace artifact size**: Large artifacts (>100KB) indicate significant agent work; small (<20KB) indicate quick default-clause fallthrough

### 4. Event Routing Analysis

For each run that executed the `orchestrate` job, determine which clause the orchestrator matched:

1. Reconstruct the event data from the run's trigger info:
   - `type` (issues / workflow_run)
   - `action` (opened / labeled)
   - `label.name` (if labeled)
   - Issue title
2. Walk through the orchestrator prompt's clause cases in order
3. Check each clause's conditions against the event data
4. Identify: **which clause matched** (or if it fell to default)
5. Flag any **title format mismatches** or **missing labels** that prevented expected matches

### 5. Gap Analysis

Compare expected outcomes vs actual outcomes:

| Expected | Actual | Gap |
|----------|--------|-----|
| Application Plan issue with title matching Clause 1 | Actual title format | Match/Mismatch |
| N epic issues created by `create-epic-v2` | Count of epic issues found | Delta |
| N PRs from `implement-epic` | Count of implementation PRs | Delta |
| Milestones with assigned issues | Milestone state | Status |
| `implementation:complete` labels applied | Label state | Status |

### 6. Debrief Document Analysis

If the orchestrator produced a debrief document (e.g. in `docs/debrief-and-document/`), fetch and summarize:

```
https://raw.githubusercontent.com/{owner}/{repo}/{branch}/docs/debrief-and-document/{report}.md
```

> **`{branch}`**: This is a placeholder for the remote branch currently being used. You can fetch the current value being used by looking in <./AGENTS.md> in the <instruction_source>.<repository>.<branch> field.

Cross-reference the debrief's self-assessment against the actual evidence gathered.

### 7. Produce the Report

Create a markdown report at `docs/{repo-name}-run-report.md` with the following sections:

> **`{repo-name}`**: Repo name without the server or owner/namespace, e.g. `workflow-orchestration-queue-zulu78-b`, `workflow-orchestration-queue-charlie80`, etc.

```markdown
# Workflow Run Report: `{repo}`

## Executive Summary
One-paragraph verdict: FULL SUCCESS / PARTIAL SUCCESS / FAILURE
What worked, what didn't, root cause in one sentence.

## Timeline of Events
Chronological table of ALL workflow runs with trigger, duration, result.

## What Worked
Subsections for each component that functioned correctly, with evidence.

## What Failed
### ROOT CAUSE: {title}
Detailed analysis of the failure chain.
Include: clause matching walkthrough, title/label mismatch details,
expected vs actual event data.

## Resource Consumption Summary
Table of billable run durations and value produced.

## Artifacts Produced
Table of trace artifacts with sizes.

## Recommendations
Numbered fixes with priority, code examples where applicable.

## Summary Table
Component-level pass/fail matrix.
```

### 8. Validate the Report

Before finalizing:

- [ ] Every claim in the report is supported by fetched evidence
- [ ] Run IDs and issue/PR numbers are accurate
- [ ] Clause matching analysis is correct (re-walk the prompt logic)
- [ ] Recommendations are actionable and specific
- [ ] No secrets or tokens appear in the report

## Key Principles

- **Evidence-first**: Every claim must reference a specific run, issue, or page
- **Clause-walk fidelity**: Reproduce the exact orchestrator prompt logic, don't guess
- **Parallel gathering**: Fetch independent data sources simultaneously
- **Trace size heuristic**: Large trace artifacts = real work; small = quick exit or default clause
- **Cross-reference**: Always compare the agent's self-reported debrief against actual outcomes
- **Actionable output**: Recommendations must include specific file/line changes, not vague suggestions

## Notes

- Template repos use `assemble-orchestrator-prompt.sh` to inject `__EVENT_DATA__` into the prompt — the assembled prompt file (`.assembled-orchestrator-prompt.md`) is inside the devcontainer workspace
- The `skip-event` job filters labels before the `orchestrate` job runs — if a run shows `skip-event: success, orchestrate: skipped`, the label was filtered out at the workflow level
- Bot actors (`traycerai[bot]`) are always skipped to prevent feedback loops
- The orchestrator prompt's clause order matters — first match wins
- Issue titles are the most fragile matching criterion; labels are more reliable
