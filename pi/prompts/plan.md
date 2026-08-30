---
description: scout -> planner -> plan.md on disk, ready to hand to a fresh agent
---

Produce an implementation plan for: $ARGUMENTS

Run this as a chain, so that the expensive reading happens in child contexts and
only the compressed results reach this one:

1. Dispatch `scout` to locate every part of the codebase this touches. Give it a
   precise question, not the raw goal.
2. Dispatch `planner` with the goal and the scout's findings.
3. Write the resulting plan verbatim to `plan.md` in the repo root.

Then stop. Do not begin implementing.

Report only the path and the step count. I will review `plan.md` myself and
start a fresh session to execute it, so there is no value in you summarizing it
back to me here -- that summary would just consume the context the next agent
needs.
