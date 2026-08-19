# Verified environment quirks

Landmines found the hard way on this machine, with how each was confirmed. All
verified 2026-08-20 on **Wolfram 15.0.1 for Microsoft Windows (64-bit)**,
installed at `C:\Program Files\Wolfram Research\Wolfram\15.0`.

Read this before concluding that strange behaviour is your own bug. Several of
these fail *silently* or blame the wrong thing.

## ZeroMQ sockets crash the kernel

`SocketOpen[addr, "ZMQ_REP"]` segfaults the kernel outright (exit 139).
Reproduced in both `wolframscript` and a standalone `wolfram.exe -script`.

Do not build anything on ZMQ here. If you need inter-process communication with
a kernel — especially the user's live front-end kernel — use files. That is why
LiveNB uses a polled mailbox rather than a socket.

Note also that plain TCP uses a different address syntax: `SocketOpen[port]`,
not `SocketOpen["tcp://127.0.0.1:port"]` (the `tcp://` scheme is a ZMQ form and
gives "the port number conflicts with the scheme specification").

## `RunScheduledTask[expr, {t}]` runs **once**, not every `t` seconds

The braced form means "once, `t` seconds from now". Only a bare number repeats.
Check the task object — the third element tells you which you got:

```wolfram
RunScheduledTask[f[], {0.1}]   (* {0.1, 1}        -> fired 1 time in 2s  *)
RunScheduledTask[f[], 0.1]     (* {0.1, Infinity} -> fired 18 times in 2s *)
```

This one is nasty because the wrong version *looks* like it works: the task
fires once at startup, so any state it sets up appears correct, and it then
never runs again.

## `ScheduledTasks[]` is broken — it returns `{}`

With a task demonstrably running (counter incrementing, mailbox being
serviced), `ScheduledTasks[]` reports an empty list. Confirmed both from a
script and from a notebook's main loop, so it isn't an artefact of being called
inside a task.

Consequence: you cannot enumerate tasks to clean up orphans. Keep the
`ScheduledTaskObject` yourself. `RemoveScheduledTask[obj]` on the object *does*
work (verified: counter froze at the value it had when removed).

## Scheduled tasks *do* fire during `Pause`

A script sitting in `While[True, Pause[0.25]]` still services its scheduled
tasks. If a task seems not to fire there, suspect the `{t}` bug above rather
than "the kernel is busy" — that was the wrong diagnosis twice here.

## The MCP kernel runs with `-noinit`

Its command line is:

```
wolfram.exe -run "PacletSymbol[...StartMCPServer...][]" -noinit -noprompt
```

So `$UserBaseDirectory/Kernel/init.m` is **not** read by the MCP kernel. Nothing
you put there will auto-load for the agent's own kernel; it only affects
front-end and script kernels. Any per-session setup on the MCP side has to be an
explicit `Get`.

## Two front-end processes is normal

The MCP server spawns its own headless front end (`WolframNB.exe /b /min
-mathlink -server`) plus a sandboxed kernel, the first time it needs to
rasterize anything. Don't mistake it for the user's front end, which has a plain
command line with no flags. Check `CreationDate` and `CommandLine` via
`Get-CimInstance Win32_Process` before concluding anything about which process
is whose.

## Front-end operations that open modal dialogs will block

`NotebookSave[nb]` on a notebook that has never been saved opens a Save dialog
and blocks until it is answered. Anything running that from a background poller
freezes until the user notices a dialog they may not connect to your request.
Guard it: check `NotebookFileName[nb]` returns a string first.

## `NotebookWrite` replaces the cell, so cell ids change

The `CellObject` uuid you targeted is dead after a write — reusing it fails
rather than editing the new cell. This is the safe behaviour, but it means ids
must be re-read after any write. LiveNB's write responses carry the new id for
this reason.
