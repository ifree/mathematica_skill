---
name: mathematica
description: Drive Wolfram Language and Mathematica through the Wolfram MCP server — symbolic algebra, calculus, ODEs, integrals, series, linear algebra, number theory, plotting, units and curated entity data — plus read and write the user's live open notebook through the bundled LiveNB bridge, and reuse a growing library of verified Wolfram scripts. Use this whenever a task touches Wolfram, Mathematica, WolframAlpha, .nb / .wl / .wls files, or "my notebook", and also whenever a maths or scientific-computing problem would be answered better by a computer algebra system than by hand or by Python — even if the user never names the tool.
---

# Wolfram Language / Mathematica

Three capabilities live here: driving the Wolfram MCP kernel, reaching the
user's *live* notebook, and a library of scripts worth keeping. Start with the
distinction below — almost every confusing failure in this domain comes from
getting it wrong.

## First: which kernel are you talking to?

There are two Wolfram kernels running and they share **nothing** — not
variables, not definitions, not loaded packages.

|  | MCP kernel | the user's notebook kernel |
| --- | --- | --- |
| reached by | `WolframLanguageEvaluator` | `NBEval`, `NBEvalCell` (via LiveNB) |
| `$Notebooks` | `False` — headless | `True` |
| sees the user's variables | no | yes |
| can touch the open notebook | no | yes |
| state persists across your calls | yes, pass the same `session` | yes |

Default to the MCP kernel. It is yours, it is fast, and nothing you do there can
disturb the user's work. Reach for the notebook kernel only when the task is
genuinely *about* their notebook, or needs definitions that live in their
session.

The same split explains the built-in `ReadNotebook` / `WriteNotebook` tools:
they run in the headless kernel, so they only ever touch `.nb` **files on
disk**. They cannot see the notebook the user is looking at. That is what
LiveNB is for.

## Driving the MCP kernel

The essentials, in rough order of how often they bite:

- **Results print as `Out[n]= …`, so shape the output.** For several values at
  once, `Column[ToString[#, InputForm] & /@ {a, b, c}]` reads far better than a
  raw nested list. `InputForm` matters — without it, long expressions come back
  in a typeset form that is hard to read back.
- **Graphics come back as images you can actually see.** `Plot[…]`,
  `Rasterize[…]`, `NBCellImage[…]` all return pictures into your context. Use
  this to check your own work, not just to hand the user a chart.
- **There is a 60-second default limit.** Pass `timeConstraint` for anything
  heavier. Batching several slow calls into one evaluation is the usual way
  people blow through it by accident.
- **Pass `session` to keep state** between calls. Without it you get a fresh
  kernel context each time.
- **`\[FreeformPrompt]["…"]` is the way in to curated data** — quantities,
  entities, units, "population of France". The argument has to be a literal
  string; it is parsed before evaluation, so it cannot be built at runtime.
- **Loading a package and using it must be two separate calls.** The whole
  evaluation is parsed before any of it runs, so symbols referenced in the same
  call bind before `Get` has defined them. This one is subtle and silent.
- **Re-`Get`ting an edited package stacks definitions** rather than replacing
  them, and the stale pattern usually wins — so your new code silently never
  runs. Check `Length[DownValues[f]]` when an edit seems to have no effect.

`reference/mcp.md` has the detail, including output-shaping recipes and the
other tools (`WolframLanguageContext`, `CodeInspector`, `TestReport`).

## The user's live notebook

`scripts/LiveNBServer.wl` runs inside the front end's kernel; the agent side
loads `scripts/LiveNBClient.wl` into the MCP kernel and gets `NBRead`,
`NBWrite`, `NBEval`, `NBCellImage` and friends.

The bridge must be started by the user, once per Mathematica session — you
cannot start it yourself, since there is no channel into their front end:

```wolfram
LiveNBStart[]
```

Read `reference/live-notebook.md` before using any of it. The two things most
likely to trip you up: cells can be addressed by position *or* by a stable id,
and positions shift under the user's edits — so prefer ids for anything
destructive. And a write returns the content it replaced, which is your check
that you hit the right cell.

## The script library

`library/` accumulates Wolfram code that turned out to be worth keeping. It is
only useful if it is actually consulted, so:

**Before writing more than a few lines of Wolfram for a task, read
`library/INDEX.md`.** It is one file, one line per entry — a cheap read that
often saves rebuilding something that already works.

### Using an entry

Each entry declares what it `provides`, so you rarely need to read the whole
file:

```wolfram
Get["<skill>/library/<slug>.wl"]   (* in its own evaluation — see the parsing note above *)
```

Check the entry's `kernel:` field first. `frontend` means it needs `$Notebooks`
and will fail in the MCP kernel; `any` runs anywhere.

### Adding an entry

Save something only if at least one of these is true:

- it took more than one attempt to get right — you debugged it
- it works around behaviour that is undocumented or outright wrong
- it is a multi-step workflow you would otherwise reconstruct from scratch

Deliberately **not** worth saving: anything `WolframLanguageContext` answers in
a single query, one-liners, and code tied to one project's data. A library of
things that were never hard to write is just noise between you and the things
that were.

Prefer improving an existing entry over adding a near-duplicate — check
`INDEX.md` first.

Write the file with this header, which is what the index is built from:

```wolfram
(* ::Library::
name:     phase-portrait
summary:  Phase portrait with nullclines for a 2D autonomous ODE system
tags:     ode, dynamics, plotting
kernel:   any
provides: PhasePortrait, NullclinePlot
verified: 15.0.1 2026-08-20
:: *)
```

Then regenerate the index — never hand-edit `INDEX.md`, it is a build product
and hand edits are how catalogues drift out of sync with what they catalogue:

```bash
wolframscript -file <skill>/scripts/index-library.wls
```

If the entry is non-trivial, add `library/tests/<slug>.wlt` alongside it. The
MCP server's `TestReport` tool runs a single test file; `scripts/verify-library.wls`
runs them all. Tests are what let a future session trust an entry it has never
seen work.

### Keeping it honest

`verified:` records the Wolfram version and date an entry last actually ran. If
you reuse an entry and it fails, fix it and bump that line — or delete it if it
turns out to be wrong. **The library is allowed to shrink.** A catalogue that
only ever grows becomes one nobody trusts, and an entry that silently no longer
works is worse than no entry at all.

## Setup

Everything works without this, but it removes the friction of typing paths:

```bash
wolframscript -file <skill>/scripts/install-init.wls
```

This patches `$UserBaseDirectory/Kernel/init.m` so that `LiveNBStart[]` is
available in any front-end session without a `Get` first. It backs the file up,
edits only between its own markers so it is safe to re-run, and installs a lazy
stub so kernel startup cost stays at zero. It does not affect the MCP kernel,
which runs with `-noinit`. Pass `"Uninstall" -> True` to remove the block.

The user decides when to run this — don't run it unprompted.

## Environment quirks

`reference/quirks.md` records landmines verified on this machine, with the
evidence. Read it before debugging anything strange — several of these cost
real time to find and look like your own bug when you hit them.
