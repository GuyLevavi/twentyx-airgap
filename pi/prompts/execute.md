---
description: execute plan.md in a clean context, one step at a time
---

Read `plan.md` and implement it. $ARGUMENTS

Rules for this session:

- Work one step at a time. After each step, run the verification command from
  the plan's Verification section before moving on.
- Do not re-read files you have already read. If you need to recall something,
  it is in your context already; searching again duplicates it.
- If you need to locate code the plan does not name, dispatch `scout` rather
  than grepping and reading here. Your context is the scarce resource; the
  child's is free.
- If a step turns out to be wrong, stop and say so. Do not improvise a
  replacement plan silently -- the plan was reviewed, your improvisation was not.

When every step passes verification, dispatch `reviewer` on the diff and report
its verdict.
