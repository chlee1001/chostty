---
name: writing-pr-descriptions
description: >-
  Writes GitHub PR titles and bodies. Activates when the user asks to
  create or update a pull request, draft a PR description, or similar.
---

# Writing PR Descriptions

Write PR titles and bodies in this fork's style: the fork's
Conventional Commits title plus a gajae-code-structured body.

## Title

```
<type>(<scope>): <summary>
```

- Title matches the squashed commit subject exactly. The fork's own
  history uses `feat(workspace):`, `fix(sidebar):`, `refactor(macos):`,
  `test:`, `ci:`, `build:`, `chore:` — match it.
- Summary: lowercase start, imperative mood, no trailing period.

## Body

```
<problem and change, plain prose>

Constraint: <invariant that must hold>
Rejected: <considered alternative> | <why it was refused>
Tested: <what was actually run>
Not-tested: <known gap>
Confidence: <high|medium|low>
Scope-risk: <low|moderate|high|narrow|...>
Reversibility: <git-revert|revert commit|...>
```

### Rules

- First paragraph states the defect or gap, then what changed and how
  the new behavior works. Plain prose, no bullets. Focus on why and
  how, not a diff restatement.
- `Constraint:` lines name invariants the change must preserve (one
  per line when more than one). Omit when there is none.
- `Rejected:` lines record a seriously considered alternative and why
  it was refused, separated by ` | `. Omit when nothing was weighed.
- `Tested:` lists only what was actually run — builds, suites with
  counts, gates, manual runs. Never claim an unrun check.
- `Not-tested:` names the known verification gap (e.g. Xcode IDE UI
  run needing accessibility permission). Omit only when nothing is
  untested.
- `Confidence:`, `Scope-risk:`, `Reversibility:` are each one line.
- No `Co-authored-by` trailer: this fork's log carries none.
- Body language is English, matching the repo docs.

## Workflow

- Draft the title from the branch diff, matching the commit subject.
- Draft the body from the defect, the change, rejected alternatives,
  and the verification actually performed.
- Create or update the PR with `gh pr create` / `gh pr edit`.
- If `gh pr edit` fails on token scopes (`read:org` missing), report
  the exact scope error and hand over the finished body text rather
  than leaving a half-edited PR.
