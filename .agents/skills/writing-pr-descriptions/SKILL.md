---
name: writing-pr-descriptions
description: >-
  Writes GitHub PR titles and bodies. Activates when the user asks to
  create or update a pull request, draft a PR description, or similar.
---

# Writing PR Descriptions

PR bodies follow the gajae-code repository's PR template
(`Yeachan-Heo/gajae-code` `.github/PULL_REQUEST_TEMPLATE.md`): `What`,
`Why`, `Testing`, `Risk classification`, then a checklist. Only the
checklist items change, to this fork's own gates. The commit-trailer
format (`Constraint:`, `Tested:`, `Confidence:` …) belongs in commit
messages, not PR bodies.

## Title

```
<type>(<scope>): <summary>
```

- Matches the squashed commit subject exactly. The fork's history uses
  `feat(workspace):`, `fix(sidebar):`, `refactor(macos):`, `test:`,
  `ci:`, `build:`, `chore:`.
- Lowercase start, imperative mood, no trailing period.

## Body

```markdown
## What

<one sentence on the user-visible change>

- <change, with the type or file that carries it>
- …

## Why

<the defect or gap, with observed evidence, and why this approach>

Alternatives considered:
- <alternative>. <why it was refused>

## Testing

- <command or suite> — <result with counts>
- Not covered: <known gap>

## Risk classification

- [ ] `low-risk` — ordinary fix/maintenance
- [ ] `regression-risk` — fix with material regression risk
- [ ] `high-risk` — <area>; independent review required

---

- [ ] Target branch is `main`
- [ ] `./macos/build.nu --configuration Debug --action build` passes
- [ ] Affected macOS test suites pass (batched, see AGENTS.md)
- [ ] `./macos/scripts/native-tab-audit.sh` passes
- [ ] README / FORK.md updated (if user-facing)
```

### Rules

- `What` opens with the visible change, then bullets naming the code
  that carries it. Describe behavior, not a diff restatement.
- `Why` states the defect with the evidence actually observed (log
  line, `defaults read`, reproduced command), the cause, and why this
  fix. Put rejected approaches under `Alternatives considered:`; omit
  that block when nothing was weighed.
- `Testing` lists only what was actually run, with counts. End with a
  `Not covered:` bullet for the known gap; omit it only when nothing
  is untested. Never claim an unrun check.
- Check exactly one risk box. Tick a checklist item only when it was
  done; leave it unchecked and say why in parentheses otherwise.
- No `Co-authored-by` trailer and no agent signature.
- English, matching the repo docs.

## Workflow

- Draft the title from the branch diff, matching the commit subject.
- Create or update the PR with `gh pr create --base main` /
  `gh pr edit`, always naming `--repo chlee1001/chostty`.
- If `gh pr edit` fails on token scopes (`read:org` missing), update
  the body through REST instead:
  `gh api -X PATCH repos/chlee1001/chostty/pulls/<n> -F body=@<file>`.
