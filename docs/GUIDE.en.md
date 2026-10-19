# Guide: using the Agent Loop in your projects

**English** · [ქართული](GUIDE.md)

A practical guide: when the loop is worth it, how to prepare a project, how to write requirements, how to supervise it, and what to do when something stops.

## 1. When it is worth it, and when not

**Worth it** when:
- the work is large and splits into many small, checkable pieces (a feature series, a migration, a long bug list);
- the project has automated checks: tests, type check, build (`verifyCommand`);
- results can be checked for real: in a browser, against an API, on files.

**Not worth it** when:
- the task is an hour of work: just do it in Claude Code;
- there are no tests or build at all: C has nothing to measure. Add minimal tests first;
- the work touches secrets, money or production data and must not ship without human review. Put those files in `protectedPaths`.

**Cost:** on a real project one round is roughly $20–35 (A + C + B + reviewer). `metrics/summary.md` always shows what it cost.

## 2. Prepare the project (once)

1. **`CLAUDE.md` in the repo.** Agents rely on it most: stack, commands (dev, test, build), code rules, what is forbidden. The more precise it is, the more precise the loop. Add the text of `CLAUDE.snippet.md` too.
2. **One verify command** that checks everything and exits non-zero on failure:
   - Node/React/Remix: `npm run verify` (lint + typecheck + test + build);
   - .NET: `dotnet build -warnaserror && dotnet test`;
   - Flutter: `flutter analyze && flutter test`.
3. **`.claude/agents/code-reviewer.md`** if you don't have one: A calls it for changes of 3+ files. The root gate has its own reviewer (`loop-reviewer`).
4. **Test servers**, if C needs a browser or an API: a `healthUrl` and a start command for each in `servers`. The loop starts them when they are down.

## 3. Configuration

See the table in the [README](../README.md#configuration-loopconfigjson). Notes:
- Keep `loopDir` **outside** the repository so reports never end up in git.
- **`consultAgents`:** B and C never change code, so give them only **read-only** project agents (no `Write`/`Edit` in their definition), for example `accessibility-auditor`, `code-reviewer`, `tech-lead`, `product-manager`. If source still changes during their phase, the gate refuses to publish that round and writes `gates/readonly-violation-*.txt`.

## 4. `requirements.md` — the most important file

B builds the backlog from it; vague requirements make a vague loop. A good requirement is:
- **one line = one checkable outcome**: not "improve UX", but "create a reminder in 3 clicks; saving with an empty title is blocked";
- **prioritised** and with **dependencies** ("F-04 after F-02");
- explicit about **what you do not want** ("we do not change auth", "Android only");
- linked to a **reference** where one exists (another product's behaviour, a video timestamp); C compares against it.

Example:
```markdown
# reminder-app — requirements
## Must
- F-01 (P1) Create a reminder: title + time; empty title → error next to the field.
- F-02 (P1) List grouped by day; today first.
- F-03 (P2, after F-01) Repeat: daily / weekly.
## Not now
- Cloud sync (next stage).
```

## 5. Running and supervising

- **Start:** `start-loop.cmd` (or `start-loop.ps1 -Config C:\...\reminder.config.json`). Before round 1, B writes `backlog.json` and the first `current-task.md`. **Read both**: if B misunderstood something, fix it now by changing `requirements.md` or adding a rule to `policy.local.md`.
- **Two minutes a day:**
  - `status.json`: where it is;
  - `metrics/summary.md`: cost, PASS/FAIL, bugs;
  - `gates/`: what was published and what was not, with reasons;
  - `b-next.json`: B's decision (CONTINUE / BLOCKED / COMPLETE).
- **Steering:** don't hand-edit code while the loop runs; you will collide with A. Write a rule in `policy.local.md` or a change in `requirements.md`; B picks it up next round.
- **Stopping:** `stop-loop.cmd`. **Resuming:** `start-loop.cmd -StartRound N -StartPhase A|C|G|B`. It continues from its files and loses nothing.

## 6. Statuses

See the table in the [README](../README.md#statuses-and-what-to-do).

## 7. Lessons from real use

- **A big task is an expensive, bad round.** If rounds cost $40+ or C often fails, add to `policy.local.md`: "one round = one stage of one feature".
- **An "offline PASS" is not a PASS.** If metrics show `real: NO`, the servers or the browser were not working. Fix the environment, not the loop.
- **History grows.** The `context/` files handle this, but if `backlog.json` passes ~500 KB, ask B to archive old closed entries.
- **One loop per repository.** Two at once split the git history.
- **A manual commit while the loop runs** changes HEAD under the gate. Stop the loop first, commit, then `start-loop -StartPhase B`.
- **Windows pitfalls are handled:** UTF-8 stdin, PowerShell 5.1 stderr behaviour, `pwsh` vs `powershell`, CR/LF-only changes.

## 8. By project type

| Project | verifyCommand | servers | What C checks |
|---|---|---|---|
| Web (React/Remix/Next) | `npm run verify` | dev server (+ API) | browser via Playwright, viewports |
| .NET API | `dotnet build -warnaserror && dotnet test` | `dotnet run` + a health endpoint | real HTTP calls, status codes, DB state |
| Flutter / mobile | `flutter analyze && flutter test` | none, or an emulator | widget/golden tests, screenshots |
| Library / CLI | `npm test` / `pytest` | none | real invocations, output comparison |
