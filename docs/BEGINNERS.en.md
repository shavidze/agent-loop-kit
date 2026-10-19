# Beginner's guide: Agent Loop Kit from zero

**English** · [ქართული](BEGINNERS.md)

This page is for people seeing the kit for the first time. It assumes no prior knowledge. It explains everything in order and in plain words, and ends with you running the loop on your own project, step by step.

**Contents**
1. [What it is, in one picture](#1-what-it-is-in-one-picture)
2. [What you get and what you don't](#2-what-you-get-and-what-you-dont)
3. [Words you need to know](#3-words-you-need-to-know)
4. [The three folders](#4-the-three-folders)
5. [One round, told as a story](#5-one-round-told-as-a-story)
6. [Every file in the kit, in plain words](#6-every-file-in-the-kit-in-plain-words)
7. [First run, step by step](#7-first-run-step-by-step)
8. [How to see what it is doing](#8-how-to-see-what-it-is-doing)
9. [Steering, stopping, resuming](#9-steering-stopping-resuming)
10. [Common problems](#10-common-problems)
11. [Tips for a safe start](#11-tips-for-a-safe-start)

---

## 1. What it is, in one picture

Imagine a small team that keeps working while you sleep:

| Who | In real life | Here | What it does |
|---|---|---|---|
| **B** | manager | `loop-planner` agent | reads your wish list, splits it into small tasks, hands A one task at a time |
| **A** | developer | `loop-implementer` agent | writes the code for that one task |
| **C** | tester | `loop-verifier` agent | opens the real application and checks that it actually works. Does **not** change code |
| **root gate** | the boss who signs off | part of `run-loop.ps1` + `loop-reviewer` | if C says "works", runs the tests, has another agent review the change, and only then uploads the code to GitHub |

They take turns in a circle. One circle is a **round**. Rounds repeat until everything on the list is done or you stop it.

Every agent is **Claude Code**, just with a different role and different permissions. The kit is not an AI itself. It is the conductor that calls Claude Code in the right order, with the right instructions and the right limits.

## 2. What you get and what you don't

**You get:**
- large work (say 30 features or 50 bugs) gets done gradually without you constantly stepping in;
- every change is checked before it lands in your repository;
- if Claude's usage limit runs out or the internet drops, the loop waits and continues where it stopped;
- a report for every round: what was done, what it cost, what failed and why.

**You don't get:**
- **magic.** If you don't write down what you want, the loop can't guess. Your wish list (`requirements.md`) is the most important file.
- **free work.** Every round spends Claude tokens. On a real project it was about $20–35 per round. `metrics/summary.md` shows you the real number.
- **a replacement for your final check.** When B says "everything is done", look at the product yourself.

## 3. Words you need to know

| Word | Meaning |
|---|---|
| **repository (repo)** | your project folder, tracked by git |
| **commit** | a saved point in git history |
| **push** | uploading commits to GitHub (or another server) |
| **branch** | a separate line of history, e.g. `main` |
| **remote** | where code is uploaded, usually `origin` (your GitHub repo) |
| **Claude Code** | Anthropic's program that runs in a terminal and writes code. The command is `claude` |
| **agent** | Claude Code with a specific role and instructions (B, A, C, reviewer) |
| **prompt** | the text instruction for an agent: "You are C, check…" |
| **PowerShell, `.ps1`** | Windows' scripting language, and a file written in it |
| **`.cmd`** | a Windows "button": double-click it and it runs the matching `.ps1` |
| **JSON** | a text format for settings: `{"name": "value"}` |
| **verify command** | one command that checks your project (tests, build) and fails if something is wrong |
| **server / health URL** | your app while it is running (e.g. `npm run dev`) and the address the loop uses to check it is alive (e.g. `http://127.0.0.1:5173/`) |
| **backlog** | the list of all tasks with their status. B builds and updates it |
| **round** | one full circle: A → C → gate → B |
| **gate** | a checkpoint code must pass before it is uploaded |

## 4. The three folders

You deal with three different folders. Getting this straight avoids most confusion:

```
C:\Tools\agent-loop-kit\      ← 1. KIT: the tool itself. One copy for all projects.
    run-loop.ps1, start-loop.cmd, ...
    loop.config.json          ← your settings (you create it)

C:\Apps\my-app\               ← 2. YOUR PROJECT (repoDir). A writes code here.
    src\, package.json, CLAUDE.md, .claude\ ...

C:\Apps\my-app-loop\          ← 3. LOOP MEMORY (loopDir). Agents write their reports here.
    requirements.md           ← your wish list (you write it)
    backlog.json, current-task.md, status.json, loop.log, gates\, metrics\ ...
```

**Why is the third folder outside the project?** So reports, logs and agent notes are never accidentally uploaded to GitHub along with your code.

## 5. One round, told as a story

Say your `requirements.md` contains: "F-01: create a reminder; empty title → error".

**Bootstrap (once).** B reads your list and the project code. It creates `backlog.json` (every task) and `current-task.md`: "Round 1: do F-01. Done when…".

**Round 1:**
1. **Server check.** The loop checks your `healthUrl`. If the app is down, it starts it.
2. **A** reads `current-task.md`, writes code in your project, runs tests, and writes a report to `a-round-1.md`. It does **not** commit; that is forbidden for it.
3. **Server check again**, strict this time. If the app still isn't up after three tries, the loop stops with `NEEDS_ATTENTION`, because C needs the real app.
4. **C** opens the app (e.g. in a browser), tries to create a reminder, tries an empty title. It writes `c-round-1.md` with a verdict, PASS or FAIL, plus any bugs found. If code changes while C is working, the loop notices and blocks the round.
5. **Root gate:**
   - C didn't say PASS? → `skipped`, nothing is uploaded;
   - PASS → it runs your `verifyCommand`. Failed? → `failed`;
   - passed → it gives the change to another agent (`loop-reviewer`). Said BLOCK? → `blocked`;
   - said `COMMIT: OK` → **commit + push**, status `published`.
   The result is written to `gates/gate-round-1.json`.
6. **B** reads everything that happened, updates the backlog (F-01 → done, or try again), and writes `current-task.md` for the next round. Its decision goes in `b-next.json`: `CONTINUE`, `BLOCKED` (needs your answer) or `COMPLETE` (everything is done).
7. **Metrics.** Cost and time are recorded.

Then round 2, 3…

## 6. Every file in the kit, in plain words

**Files you touch:**

| File | What it is | What you do |
|---|---|---|
| `loop.config.json` | your settings: where the project is, where to push, how to check it | create it once from `loop.config.example.json` |
| `<loopDir>/requirements.md` | your wish list | write it once, add to it as needed |
| `<loopDir>/policy.local.md` | your extra rules for the loop (optional) | create it when you want the loop to behave differently |
| `start-loop.cmd` | the start button | double-click |
| `stop-loop.cmd` | the stop button | double-click |

**Files you normally leave alone:**

| File | What it is |
|---|---|
| `run-loop.ps1` | the loop's engine: calls the agents in turn, checks servers, waits out limits, runs the gate, commits and pushes |
| `start-loop.ps1` / `stop-loop.ps1` | what the `.cmd` buttons actually run: start in the background, stop every process |
| `agents.json` | describes the four agents and what each may do |
| `prompts/A.md`, `B.md`, `C.md`, `B0-initial.md` | the instructions for each agent (`B0-initial` is the first, bootstrap step) |
| `policy.md` | shared rules sent to every agent |
| `templates/` | the shape of the backlog and task files |
| `tools/build-context.mjs` | before each phase, prepares a short summary for the agents so they don't read the whole history |
| `tools/loop-metrics.mjs` | counts cost, time and results into `metrics/` |
| `tools/watch-context.py` | watches whether an agent's memory is getting full, and restarts it if so |
| `CLAUDE.snippet.md` | a short text to add to your project's `CLAUDE.md` |
| `README*.md`, `docs/` | documentation |

## 7. First run, step by step

The examples are for Windows. Replace `C:\Apps\my-app` with your project's path.

### Step 1. Install what you need

Open **PowerShell** (Start → type "PowerShell") and check:
```powershell
claude --version
git --version
node --version
```
Each should print a version. If one says "not recognized", install it:
- **Claude Code:** instructions at [docs.claude.com](https://docs.claude.com). After installing, run `claude` once and sign in;
- **Git:** [git-scm.com](https://git-scm.com);
- **Node.js:** [nodejs.org](https://nodejs.org) (LTS version);
- **Python** (optional, for the watchdog): [python.org](https://www.python.org).

### Step 2. Make sure your project is ready

```powershell
cd C:\Apps\my-app
git status
git push
```
- `git status` must not say "not a git repository". Ideally it says "nothing to commit, working tree clean", meaning all your changes are committed;
- `git push` must work without errors. If you can't push by hand, the loop can't either.

### Step 3. Find your verify command and run it by hand

This is the command that says "the project is OK". Examples:

| Project | Command |
|---|---|
| Node / React | `npm test` or `npm run build`, or both: `npm test && npm run build` |
| .NET | `dotnet build -warnaserror && dotnet test` |
| Flutter | `flutter analyze && flutter test` |
| Python | `pytest` |

Run it now, by hand. **It must pass now.** If it fails now, the gate will fail every round and nothing will be uploaded. Fix that first.

### Step 4. Download the kit

```powershell
git clone https://github.com/shavidze/agent-loop-kit C:\Tools\agent-loop-kit
```

### Step 5. Create `loop.config.json`

In `C:\Tools\agent-loop-kit`, copy `loop.config.example.json` and name the copy `loop.config.json`. Open it in Notepad or VS Code and edit it. A complete example for a project that needs no server:

```json
{
  "projectName": "my-app",
  "repoDir": "C:/Apps/my-app",
  "loopDir": "C:/Apps/my-app-loop",
  "branch": "main",
  "pushRemotes": ["origin"],
  "verifyCommand": "npm test && npm run build",
  "servers": [],
  "protectedPaths": [],
  "models": { "planner": "", "implementer": "", "verifier": "", "reviewer": "" },
  "consultAgents": { "planner": [], "implementer": [], "verifier": [], "reviewer": [] },
  "commitType": "feat",
  "commitScope": "",
  "roundLimit": 3,
  "maxLimitWaitSeconds": 21600,
  "contextRestartTokens": 650000
}
```

Field by field:
- **`repoDir`**: your project's path. Use `/`, not `\`;
- **`loopDir`**: a new, empty folder **outside** the project. The loop creates it if it doesn't exist;
- **`branch`** and **`pushRemotes`**: where to push. A separate branch is best for a first try (see [tips](#11-tips-for-a-safe-start));
- **`verifyCommand`**: the command from step 3;
- **`servers`**: empty (`[]`) if C doesn't need the app running. For a web app:
  ```json
  "servers": [
    { "name": "web", "healthUrl": "http://127.0.0.1:5173/",
      "startFile": "cmd.exe", "startArgs": ["/c", "npm", "run", "dev"], "cwd": "C:/Apps/my-app" }
  ]
  ```
  That reads: "if `http://127.0.0.1:5173/` doesn't answer, run `npm run dev` in `C:/Apps/my-app`";
- **`protectedPaths`**: files the loop must never upload, e.g. `"src/auth/login.ts"`. If A changes one, the gate blocks the round and you decide;
- **`models`**: empty means your usual Claude model;
- **`consultAgents`**: if your project has its own agents in `.claude/agents/`, list which role may call which. Leave it empty at first;
- **`roundLimit`**: how many rounds before it stops. **Set 3 the first time**, to see how it works and what it costs.

### Step 6. Write `requirements.md`

Create `C:\Apps\my-app-loop\requirements.md`:

```markdown
# my-app — requirements

## Must
- F-01 (P1) Create a reminder: title + time; saving with an empty title → error next to the field.
- F-02 (P1) Reminders listed by day; today first.
- F-03 (P2, after F-01) Repeat: daily / weekly.
- BUG-01 (P1) The list disappears when the page is refreshed.

## Not now
- Cloud sync.
- Changing the login system.
```

Rules for a good list:
- **one thing per line**, written so it can be checked. "Improve the design" is bad. "The Save button is under the form and disabled while the form is empty" is good;
- an **ID** (F-01, BUG-01), a **priority** (P1 = most important) and a **dependency** ("after F-01");
- a **"Not now"** section: what it must not touch.

### Step 7 (recommended). Help the agents understand your project

In your project, create or extend `CLAUDE.md`. Write briefly:
- what the project is and its tech stack;
- commands: how to start it, how to run tests;
- rules: what is not allowed.

Paste the text of `CLAUDE.snippet.md` at the end. The better the project is described, the better the loop works.

### Step 8. Start it

In `C:\Tools\agent-loop-kit`, double-click **`start-loop.cmd`**. You will see:
```
Loop started (pid 12345). Status: C:\Apps\my-app-loop\status.json  Log: C:\Apps\my-app-loop\loop.log
Context watchdog started (pid 12346).
```
You can close the window; the loop keeps running in the background.

### Step 9. The first 15–30 minutes: check that it understood you

Open `C:\Apps\my-app-loop\status.json`:
```json
{ "phase": "B_BOOTSTRAP", "round": 0, "detail": "B turns requirements.md into backlog.json and round 1." }
```
When `phase` changes to `A_IMPLEMENTING`, B has finished bootstrapping. Now read:
- `backlog.json`: is every requirement on the list?
- `current-task.md`: is the first task understood correctly?
- `b-round-0.md`: B's questions, if any.

Something wrong? Stop it (`stop-loop.cmd`), fix `requirements.md`, delete `current-task.md` and `backlog.json` from `loopDir`, and start again.

### Step 10. After the first round

Open `gates/gate-round-1.json`. `"status": "published"` means the change was uploaded; you will see a new commit on GitHub. Any other status has a `reason` field explaining why not (see the [status table](../README.md)).

After 3 rounds the loop stops by itself (`roundLimit: 3`). Look at `metrics/summary.md` (what it cost). If you are happy, raise `roundLimit` and start again.

## 8. How to see what it is doing

| I want to know… | Where to look (in `loopDir`) |
|---|---|
| What is it doing right now? | `status.json`: `phase` and `detail` |
| Everything that happened, in time order | `loop.log` |
| What should it do this round? | `current-task.md` |
| What did A do? | `a-round-N.md` |
| What did C find? | `c-round-N.md` |
| Was it uploaded, and why or why not? | `gates/gate-round-N.json` |
| What did the reviewer say? | `gates/round-N/review.md` |
| Why did the tests fail? | `gates/round-N/verify.log` |
| What tasks are left? | `backlog.json`, `feature-status.md` |
| What did it cost? | `metrics/summary.md`, `metrics/rounds.csv` |

`phase` values: `B_BOOTSTRAP` (initial planning), `A_IMPLEMENTING` (A writes code), `C_VERIFYING` (C checks), `B_PLANNING_NEXT` (B plans the next round), `ENV_CHECK` (starting servers), `WAITING_LIMIT` / `WAITING_RETRY` (waiting), `NEEDS_ATTENTION` (needs you), `AWAITING_ROOT_VERIFICATION` (B thinks everything is done), `ROUND_LIMIT_REACHED` (hit `roundLimit`).

## 9. Steering, stopping, resuming

- **I want it to do something differently.** Do **not** edit code by hand while the loop runs; you will collide with A. Instead:
  - a new or changed requirement → `requirements.md`;
  - a rule ("keep rounds small", "always write tests") → `policy.local.md`.
  B picks it up in the next round.
- **Stop:** double-click `stop-loop.cmd`.
- **Resume:** double-click `start-loop.cmd`. It continues from the last recorded round.
- **Resume from a specific point** (in PowerShell, in the kit folder):
  ```powershell
  .\start-loop.ps1 -StartRound 5 -StartPhase C
  ```
  Phases: `A` (write code), `C` (check), `G` (gate), `B` (plan).
- **I want to commit something myself.** Stop the loop first, commit, then start it with `-StartPhase B`.

## 10. Common problems

| What you see | Cause | What to do |
|---|---|---|
| `NEEDS_ATTENTION` + "Write …requirements.md first" | no `requirements.md` in `loopDir` | create it (step 6) |
| "Loop already running (pid …)" | the loop is already on | `stop-loop.cmd` first |
| gate `failed` every round | `verifyCommand` fails | open `gates/round-N/verify.log`, run the same command by hand, fix it |
| `NEEDS_ATTENTION` + "Servers not healthy" | the app didn't start, or `healthUrl` is wrong | check `servers/*.log`, the port, and start the app by hand to see whether it works |
| gate `committed_not_pushed` | commit worked, push didn't | check that `git push` works by hand (auth, branch) |
| gate `blocked` + protected | A changed a protected file | review it yourself; commit by hand if it's needed |
| `WAITING_LIMIT` for a long time | Claude usage limit reached | nothing; it continues after the reset (at most `maxLimitWaitSeconds`) |
| `NEEDS_ATTENTION` + a question from B | B needs your decision | read `b-round-N.md`, answer in `requirements.md` or `policy.local.md`, start again |
| rounds are too expensive | tasks are too big | `policy.local.md`: "one round = one small stage of one feature" |
| C often says FAIL, `real: NO` | C couldn't see the real app | fix `servers` and `healthUrl` |

## 11. Tips for a safe start

- **`roundLimit: 3` the first time.** Look at the quality and the cost, then raise it.
- **A separate branch the first time.** Run `git switch -c loop-try`, `git push -u origin loop-try`, and set `"branch": "loop-try"` in the config. If you like the result, merge it into `main` later.
- **Protected files.** Put everything that touches money, passwords or user data in `protectedPaths`.
- **One project = one loop.** Never run two loops on the same repo at once.
- **The last word is yours.** When the loop says "done" (`AWAITING_ROOT_VERIFICATION`), open the app and check it yourself.

---

More detail: [README](../README.md) (how it works and why) · [GUIDE](GUIDE.en.md) (lessons from real use, per project type)
