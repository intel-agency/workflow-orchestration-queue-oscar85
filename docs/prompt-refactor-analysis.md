# Orchestrator Prompt Refactor — Analysis & Recommendations

> **Status: All fixes implemented** (2026-03-25)
>
> Issues A, B, C, D, E, F have been implemented across 3 repos.

## 1. Design Summary

The refactor replaces the old monolithic 4-step-per-clause approach with a **label-driven finite state machine** where each clause does exactly one workflow step and then applies the next `orchestration:*` label to advance state.

### State Transitions

```
orchestration:plan-approved   → create-epic-v2   → orchestration:epic-ready
orchestration:epic-ready      → implement-epic   → orchestration:epic-implemented
orchestration:epic-implemented → review-epic-prs  → orchestration:epic-reviewed
orchestration:epic-reviewed   → report + debrief → orchestration:epic-complete
orchestration:epic-complete   → find_next_unimplemented_line_item()
                                → create-epic-v2  → orchestration:epic-ready  (loops)
```

### Entry Points

| Entry Point | Trigger | Clause |
|---|---|---|
| Project setup dispatch | `issues.opened` + title contains `orchestrate-dynamic-workflow` | Dispatches `project-setup` |
| Plan approved (initial) | `issues.labeled` + `orchestration:plan-approved` | Creates first epic |
| Epic complete (loop) | `issues.labeled` + `orchestration:epic-complete` + `epic` | Creates next epic |

### Strengths

- Each step is **isolated, idempotent** — a single run does one thing
- Clear **audit trail** via labels — every issue shows its full orchestration history
- **No concurrency races** from monolithic clauses running 4 steps inline
- Easy to **retry** a failed step by removing and re-applying the label
- Clean **separation of concerns** between prompt clauses

---

## 2. Critical Issues

### Issue A: YAML `skip-event` / `orchestrate` filters block ALL `orchestration:*` labels

**Severity:** BLOCKER — the entire state machine is dead on arrival.

**Location:** `.github/workflows/orchestrator-agent.yml` lines 34–38 (skip-event) and lines 59–63 (orchestrate)

**Problem:** The current YAML hard-codes a whitelist of exactly two labels:

```yaml
# skip-event fires (blocking orchestrate) when label is NOT one of:
github.event.label.name != 'implementation:ready' &&
github.event.label.name != 'implementation:complete'

# orchestrate fires only when label IS one of:
github.event.label.name == 'implementation:ready' ||
github.event.label.name == 'implementation:complete'
```

The refactored prompt matches on `orchestration:plan-approved`, `orchestration:epic-ready`, `orchestration:epic-implemented`, `orchestration:epic-reviewed`, and `orchestration:epic-complete`. **None of these pass the YAML filter.** Every `orchestration:*` label event will hit `skip-event` and the `orchestrate` job will be skipped entirely.

**Fix:** Replace the hard-coded label whitelist with a prefix-based match using `startsWith()`:

```yaml
# skip-event
if: >-
  github.actor == 'traycerai[bot]' ||
  (github.event_name == 'issues' &&
   github.event.action == 'labeled' &&
   !startsWith(github.event.label.name, 'orchestration:'))

# orchestrate
if: >-
  github.actor != 'traycerai[bot]' &&
  (github.event_name != 'issues' ||
   github.event.action != 'labeled' ||
   startsWith(github.event.label.name, 'orchestration:'))
```

This whitelists any label starting with `orchestration:` and blocks everything else. It's forward-compatible — adding new `orchestration:*` states requires no YAML changes.

---

### Issue B: `/orchestrate-single-assignment` command does not exist

**Severity:** BLOCKER — step 3 (debrief) clause will crash.

**Location:** `orchestrator-agent-prompt.md` lines 180 and 187

**Problem:** The `orchestration:epic-reviewed` clause calls:

```
/orchestrate-single-assignment
    assignment_name = report-progress { $epic = $implemented_epic }

/orchestrate-single-assignment
    assignment_name = debrief-and-document { $epic = $implemented_epic }
```

There is no `.opencode/commands/orchestrate-single-assignment.md` file anywhere in the repo. The opencode agent will fail or hallucinate.

**Fix:** Use the existing `single-workflow` dynamic workflow instead:

```
/orchestrate-dynamic-workflow
    $workflow_name = single-workflow { $workflow_assignment = report-progress, $epic = $implemented_epic }

/orchestrate-dynamic-workflow
    $workflow_name = single-workflow { $workflow_assignment = debrief-and-document, $epic = $implemented_epic }
```

The `single-workflow.md` dynamic workflow already exists at `ai_instruction_modules/ai-workflow-assignments/dynamic-workflows/single-workflow.md` and is designed for exactly this use case — wrapping a single assignment with dynamic workflow features.

---

### Issue C: `.labels.json` missing all `orchestration:*` labels

**Severity:** HIGH — labels may fail to be applied or be created with wrong metadata.

**Location:** `.github/.labels.json`

**Problem:** The label definitions file has no entries for any of the 5 new `orchestration:*` labels. When the orchestrator agent tries `gh issue edit --add-label orchestration:epic-ready`, GitHub will auto-create the label with a random gray color and no description. If the repo has label creation restrictions, the operation fails silently.

**Fix:** Add all 5 labels to `.labels.json`:

| Label | Color | Description |
|---|---|---|
| `orchestration:plan-approved` | `0052cc` | Plan reviewed and approved — begin epic creation |
| `orchestration:epic-ready` | `1d76db` | Epic created — ready for implementation |
| `orchestration:epic-implemented` | `5319e7` | Epic implemented — ready for PR review |
| `orchestration:epic-reviewed` | `c5def5` | PRs reviewed and merged — ready for debrief |
| `orchestration:epic-complete` | `0e8a16` | Epic fully complete — advance to next |

Also add the dispatch label (see Issue D):

| `orchestration:dispatch` | `bfd4f2` | Dispatch issue — triggers orchestrate-dynamic-workflow |

Also clean up labels that are no longer used by the prompt:
- Remove `implementation:ready` (replaced by `orchestration:plan-approved`)
- Remove `implementation:complete` (replaced by `orchestration:epic-complete`)
- Remove `epic:creation-deferred` (no longer needed with the new FSM)

---

### Issue D: `issues: types` still includes `opened` — spurious triggers

**Severity:** MEDIUM — wastes compute on every new issue.

**Location:** `.github/workflows/orchestrator-agent.yml` line 4

**Problem:** `types: [opened, labeled]` fires the workflow for **every new issue** in the repo. Most fall through to `(default)`, but each one spins up a full devcontainer (~2-3 minutes of compute).

The only clause using `opened` is the `orchestrate-dynamic-workflow` dispatch clause (title contains "orchestrate-dynamic-workflow"). All other clauses use `labeled`.

**Fix:**
1. Remove `opened` from `issues: types` → `types: [labeled]`
2. Add new label `orchestration:dispatch` to `.labels.json`
3. Update `trigger-project-setup.ps1` to apply `orchestration:dispatch` label to the dispatch issue after creation
4. Update the dispatch clause in the prompt from `action = opened` to `action = labeled && labels contains: "orchestration:dispatch"`

---

## 3. Moderate Issues

### Issue E: Missing handoff — who applies `orchestration:plan-approved`?

**Severity:** BLOCKER — the chain never starts after project-setup completes.

**Problem:** The flow today is:

1. `trigger-project-setup.ps1` creates a dispatch issue → fires dispatch clause → runs `project-setup`
2. `project-setup` runs `create-app-plan` (step 2 of 5) which applies `implementation:ready`
3. project-setup continues steps 3-5 (`create-project-structure`, `create-agents-md-file`, `debrief-and-document`)
4. project-setup completes — **but nobody ever applies `orchestration:plan-approved`**

The state machine stalls after project-setup because clause 1 matches on `orchestration:plan-approved`, not `implementation:ready`.

**Recommended fix (Option 3):**
- Add a `post-script-complete` event to `project-setup.md` (in the `agent-instructions` repo) that applies the `orchestration:plan-approved` label to the plan issue after all 5 steps complete
- This preserves the correct sequencing: all setup steps finish before epic creation begins
- Remove the `implementation:ready` labeling from `create-app-plan.md` entirely (see Issue F)

### Issue F: `create-app-plan.md` still applies `implementation:ready`

**Severity:** MEDIUM — latent re-entrancy risk if someone re-adds `implementation:ready` to the YAML filter.

**Location:** `nam20485/agent-instructions` repo, `ai_instruction_modules/ai-workflow-assignments/create-app-plan.md` lines 28, 86, 123

**Problem:** The remote assignment file explicitly instructs agents to apply `implementation:ready` at three points:
- Acceptance criterion #18
- Detailed Step 2 (final bullet)
- Completion section

With the YAML filter fix (Issue A), `implementation:ready` won't match the `orchestration:` prefix filter, so it becomes harmless noise. But it's confusing and creates a latent risk if the whitelist is ever broadened.

**Fix:** Update `create-app-plan.md` in `nam20485/agent-instructions` to:
1. Remove all references to applying `implementation:ready`
2. The label application responsibility now belongs to the `project-setup.md` `post-script-complete` event (which applies `orchestration:plan-approved`)

---

## 4. Minor Issues / Hardening (Not in scope for current fix)

| # | Issue | Severity | Description |
|---|---|---|---|
| G | "newly-created epic issue" copy | Low | Several clauses say "apply label to the **newly-created** epic issue" when they're operating on an existing epic. Minor copy issue that could confuse the LLM. |
| H | Serial vs batch epic creation | Info | The FSM creates epic 1, implements it, then creates epic 2. This is valid serial pipeline behavior. Confirm this is intended vs. "batch create all epics first." |
| I | No failure labels | Low-Med | If a step fails, the clause says "skip to Final" but doesn't apply a failure label. The epic stays labeled at its current state with no recovery path. Consider adding `orchestration:epic-failed`. |
| J | Bot actor guard on dispatch clause | Low | The dispatch clause doesn't guard against bot actors creating issues with matching titles. |
| K | No `concurrency` key on workflow YAML | Medium | Two parallel `orchestration:*` label events could race. Add `concurrency: { group: orchestrator-${{ github.repository }}, cancel-in-progress: false }`. |
| L | Old labels still in .labels.json | Low | `implementation:ready`, `implementation:complete`, `epic:creation-deferred` are no longer referenced by any prompt clause. Clean up or document as reserved. |

---

## 5. Files Changed by Recommended Fixes

| File | Repo | Issues Addressed | Status |
|---|---|---|---|
| `.github/workflows/orchestrator-agent.yml` | `ai-new-workflow-app-template` | A, D | **DONE** |
| `.github/workflows/prompts/orchestrator-agent-prompt.md` | `ai-new-workflow-app-template` | B, D | **DONE** |
| `.github/.labels.json` | `ai-new-workflow-app-template` | C, D, L | **DONE** |
| `scripts/trigger-project-setup.ps1` | `workflow-launch2` | D | **DONE** |
| `ai_instruction_modules/ai-workflow-assignments/dynamic-workflows/project-setup.md` | `agent-instructions` | E | **DONE** |
| `ai_instruction_modules/ai-workflow-assignments/create-app-plan.md` | `agent-instructions` | F | **DONE** |

## 6. Implementation Details

### Issue A — YAML filter (DONE)

Replaced hard-coded `implementation:ready`/`implementation:complete` label whitelist in both
`skip-event` and `orchestrate` job `if:` conditions with `startsWith(github.event.label.name, 'orchestration:')`.
This is forward-compatible — adding new `orchestration:*` states requires no YAML changes.

### Issue B — Missing command (DONE)

Replaced both `/orchestrate-single-assignment` calls in the `orchestration:epic-reviewed` clause
with `/orchestrate-dynamic-workflow $workflow_name = single-workflow { $workflow_assignment = ... }`,
using the existing `single-workflow.md` dynamic workflow.

### Issue C — Labels (DONE)

Added 6 new `orchestration:*` labels to `.labels.json`:
- `orchestration:dispatch`, `orchestration:plan-approved`, `orchestration:epic-ready`,
  `orchestration:epic-implemented`, `orchestration:epic-reviewed`, `orchestration:epic-complete`

Removed 3 stale labels: `implementation:ready`, `implementation:complete`, `epic:creation-deferred`.

### Issue D — Remove `opened` trigger (DONE)

1. Changed `types: [opened, labeled]` → `types: [labeled]` in YAML
2. Changed dispatch clause from `action = opened && title contains` to `action = labeled && labels contains: "orchestration:dispatch"`
3. Updated `trigger-project-setup.ps1` to pass `-Labels @('orchestration:dispatch')` to `create-dispatch-issue.ps1`

### Issue E — Plan-approved handoff (DONE)

Added `post-script-complete` event to `project-setup.md` that applies `orchestration:plan-approved`
to the plan issue after all 5 setup assignments complete. Updated acceptance criteria.

### Issue F — Remove `implementation:ready` from `create-app-plan.md` (DONE)

Removed all 3 references (acceptance criterion #18, detailed step, completion section).
Added note explaining that `orchestration:plan-approved` is applied by `project-setup`'s
`post-script-complete` event, not by this assignment.
