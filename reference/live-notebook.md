# LiveNB — let the agent read and write your open notebook

The Wolfram MCP server's `ReadNotebook`/`WriteNotebook` only touch `.nb` files on
disk. Its kernel is headless (`$Notebooks == False`, `$FrontEnd == Null`, a
separate process from `WolframNB.exe`), so it cannot see the notebook you
actually have open.

LiveNB bridges the two: a small server runs **inside your front end's kernel**,
where `$Notebooks` is `True`, and the agent's headless kernel talks to it.

```
Claude Code ──► Wolfram MCP kernel ──► file mailbox ──► your front end's kernel ──► live notebook
                    (headless)            ~100ms                (LiveNBServer.wl)
```

## Setup

If `scripts/install-init.wls` has been run, the user only needs `LiveNBStart[]`
in the notebook they want exposed, and can skip the `Get`. The long form below
always works.

In the notebook you want the agent to drive, evaluate:

```wolfram
Get["C:/Users/ifree/.claude/skills/mathematica/scripts/LiveNBServer.wl"]; LiveNBStart[]
```

That binds **that** notebook and starts the bridge. Switching windows afterwards
changes nothing — the agent only ever touches the bound notebook. To retarget:

```wolfram
LiveNBBind[]              (* bind whichever notebook you evaluate this in *)
LiveNBBind["Untitled-3"]  (* bind by window-title substring *)
LiveNBStatus[]            (* what am I bound to? *)
LiveNBStop[]              (* shut the bridge down *)
```

The agent side loads once per kernel session, in its own evaluation:

```wolfram
Get["C:/Users/ifree/.claude/skills/mathematica/scripts/LiveNBClient.wl"]
```

## Agent-side API

| Call | Does |
| --- | --- |
| `NBStatus[]` | bound notebook's title, path, cell count |
| `NBRead[]`, `NBRead[n]` | outline of every cell, each truncated at `n` chars (default 400) |
| `NBReadCell[c]` | full text of cell `c` |
| `NBCellImage[c]` | cell `c` rendered as an image — lets the agent *see* a plot |
| `NBSelection[]` | which cells you have selected right now |
| `NBWrite[c, style, text]` | replace cell `c`; returns the content it replaced |
| `NBInsert[c, style, text]` | insert after cell `c` (`0` = top) |
| `NBAppend[style, text]` | append at the end |
| `NBDelete[c]` | delete cell `c`; returns what was deleted |
| `NBEvalCell[c]` | evaluate cell `c` in place, in the front end |
| `NBEval["code"]` | evaluate in the notebook's own kernel — sees your variables |
| `NBSave[]` | save the notebook |

A cell argument `c` is either a 1-based position in visual order (`Cells[nb]`)
or the stable `"id"` string that `NBRead`, `NBReadCell` and `NBSelection` return
for every cell. Positions shift when the notebook is edited; ids follow the cell
and fail with `CellGone` once it's gone. `"Input"`,
`"Code"` and `"Program"` cells are parsed into real boxes by the front end, so
agent-written code looks like code you typed; other styles are written as plain
text.

## Design notes

- **Why a file mailbox, not a socket.** `SocketOpen[..., "ZMQ_REP"]` segfaults
  the kernel in this Wolfram 15.0.1 install (reproduced in both `wolframscript`
  and a standalone `wolfram.exe`). The server runs in your live session, so the
  transport must not be able to crash it. Requests are written as
  `req-<id>.wxf`, picked up by a scheduled task every 100 ms, and answered as
  `resp-<id>.wxf`. Both sides write to a `.part` file and rename, so a reader
  never sees a partial message. Measured round trip: ~113 ms.
- **`RunScheduledTask[expr, {t}]` is a trap.** The braced form means "run once,
  `t` seconds from now" — the task object reads `{t, 1}`. Only a bare number
  repeats: `RunScheduledTask[expr, t]` gives `{t, Infinity}`. The braced form
  cost an hour here: the poller fired exactly once at startup, before any
  request existed, and the bridge then accepted requests forever without ever
  answering one.
- **Auth, and its limits.** `LiveNBStart[]` mints a random per-session token,
  written to `endpoint.json` next to the mailbox. Requests carrying the wrong
  token are rejected, which is what stops a stale client from talking to a
  restarted bridge. It is *not* a security boundary: `endpoint.json` lives in
  your own AppData with ordinary permissions, so anything already running as
  you can read the token and drive the notebook. The bridge is exactly as
  trusted as your user account.
- **`ScheduledTasks[]` is broken in 15.0.1** — it reports `{}` with a task
  demonstrably running, from both a script and a notebook's main loop. So
  orphaned pollers cannot be found and swept after the fact, which is why the
  package's state variables are initialised with `If[!ValueQ[...]]`: re-`Get`ing
  the file must not drop the handle to a live task. `RemoveScheduledTask` on
  the object itself does work.
- **Payloads** are WXF (`BinarySerialize`), so arbitrary expressions — including
  `Image` objects — survive the trip intact.
- **Whitelist.** Only the functions in `$api` are callable via `"call"`.
  `NBEval` is the deliberate escape hatch and evaluates in `Global`.
- **Why the entry points live in `Global\``.** A notebook parses an entire cell
  before evaluating any of it. In `Get[...]; LiveNBStart[]` the symbol
  `LiveNBStart` is therefore created — in `Global\`` — *before* `Get` runs. Had
  the package exported it from `LiveNB\`Server\``, that already-parsed reference
  would point at an empty `Global\`` symbol and the cell would silently echo back
  unevaluated, having done nothing. Defining the four entry points directly into
  `Global\`` means `Get` fills in the very symbol the cell already refers to.
  The client hits the same hazard from the other side and handles it by removing
  the shadowing symbols on load, which is why `LiveNBClient.wl` must be loaded
  in its own evaluation, separate from the one that calls `NB*`.
- Wolfram messages raised during a call come back in a `"messages"` key rather
  than being silently swallowed.

## Evaluating cells: why the client waits

`NBEvalCell` waits for the evaluation to finish before returning, and that
default is load-bearing.

`FrontEndTokenExecute[nb, "EvaluateCells"]` only *queues* the evaluation. The
front end writes the result at whatever the selection is when the result
arrives. So if you issue a second `NBEvalCell` before the first has landed, its
`SelectionMove` pulls the selection out from under the front end and the first
result is written into the wrong cell — observed as a `GraphicsBox` output
sitting in a cell still styled `Input`. Nothing errors; the user just finds
their notebook quietly mangled.

**The server cannot do this waiting.** The kernel that would have to wait is
the same kernel the front end must call to run the cell, so waiting inside the
poller deadlocks: the queued evaluation can never start. It has to be the
client that polls.

The completion signal is `$Line`. A front-end evaluation increments it;
`NBEval` does not, because it runs inside the poller rather than through the
kernel's main loop. That distinction is what makes it usable. Cell count would
*not* work — an expression ending in `;` produces no output cell at all, yet
has certainly been evaluated.

```wolfram
NBEvalCell[id]                    (* waits; returns "completed" -> True *)
NBEvalCell[id, "Wait" -> False]   (* fire-and-forget: then do not queue another *)
NBEvalCell[id, "Timeout" -> 300]  (* for genuinely long evaluations *)
```

Cells whose style isn't `Input` or `Code` are not evaluatable, so the front end
does nothing and `$Line` never moves. `NBEvalCell` detects this from the style
the server reports and returns immediately rather than waiting out the timeout.

## Known limitations

- **Prefer ids over indices for anything destructive.** An index is a visual
  position and shifts as soon as the user inserts or deletes a cell, so an
  index captured by `NBRead` can point at a different cell by the time
  `NBWrite` runs. Ids don't move. Indices remain available because they're far
  easier to talk about. As a backstop either way, `NBWrite` and `NBDelete`
  return the content they overwrote.
- **A write mints a new id.** `NotebookWrite` replaces the cell rather than
  editing it, so the id you targeted is dead afterwards and reusing it gives
  `CellGone`. The write's own response carries the replacement's `id`.
- **Agent writes move your cursor.** `NotebookWrite[..., All]` selects what it
  wrote and `NBEvalCell` selects the cell it evaluates, so your selection jumps
  if you happen to be typing.
- **`NBRead` is O(whole notebook).** It reads every cell, output cells included,
  before truncating. On a notebook full of large graphics outputs that means
  pulling all of it through the front end each time. Truncation keeps the
  *wire* payload small, not the work.
- **`parsed -> False` is rare and not a syntax check.** The front end's parser
  is deliberately lenient — it happily boxifies incomplete input like
  `f[x_] := `, because that is what you get while typing. The flag only goes
  false when the parser fails outright.
- **A modal dialog in the front end freezes the bridge**, since the poller runs
  in that kernel. `save` is guarded against the common case (an unsaved
  notebook), but anything else that opens a dialog will block until answered.
- **`NBEval` is bounded at `$maxEvalSeconds` (120)**, so a runaway evaluation
  can't wedge the bridge permanently — but while it runs, the poller is busy
  and other calls simply wait.

## Files

All under the skill's `scripts/` directory:

- `LiveNBServer.wl` — runs in the front end's kernel
- `LiveNBClient.wl` — runs in the MCP server's headless kernel
- `install-init.wls` — optional; puts lazy `LiveNBStart[]` stubs in `init.m`
- `test-stub-server.wls` — headless transport regression test; stubs out the
  front-end-dependent API and drives `poll[]` manually
- `test-fe-server.wls` — full end-to-end test against a real (hidden, throwaway)
  front end via `Developer\`UseFrontEnd`, exercising every front-end-dependent
  function.

Note the split in what each harness proves. `test-fe-server.wls` drives `poll[]`
from the server's own scheduled task, which is what validates the mailbox
plumbing; but its scheduled task fires *outside* the script's
`Developer\`UseFrontEnd` scope, so `Notebooks[]` sees no front end there. The
notebook API itself was validated in an earlier variant of the same harness that
called `poll[]` inline, inside the front-end scope. Both halves are covered; the
combination only occurs in a real notebook session, where the kernel always has
a front end.