# CURRENT TASK — Round N: <one-line title>

Planner: B · Implementer: A · Verifier: C · Date: <yyyy-mm-dd>

## Why this round
<previous round's C result in 3 lines; the requirement this slice serves, with its id>

## Baseline
- HEAD `<sha>`; working tree: <clean | listed paths>. If HEAD differs, stop and report.
- Frozen files: <list or hash list path> — must stay byte-identical.

## Scope
<exact behaviour to build; names of new exports; what is explicitly NOT in this round>

## File ownership (nothing else may change)
| May modify or create | Why |
|---|---|
| `<path>` | <reason> |

## Acceptance (C)
| ID | Check | Evidence that means PASS |
|---|---|---|
| R<N>-1 | <real user action and expected result> | <measurement / screenshot / log> |

## What could break (C re-checks)
<neighbouring flows>

## Next (orientation only)
<the following slice>
