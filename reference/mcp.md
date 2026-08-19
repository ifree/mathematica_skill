# Driving the Wolfram MCP server

The server exposes seven tools. Six are straightforward; almost all the craft is
in `WolframLanguageEvaluator`.

| Tool | What it's for |
| --- | --- |
| `WolframLanguageEvaluator` | evaluate code in the headless MCP kernel |
| `WolframLanguageContext` | semantic search over Wolfram docs, function/data/neural-net repositories |
| `SymbolDefinition` | readable definition of one or more symbols |
| `CodeInspector` | lint a code string, file, or directory |
| `TestReport` | run a `.wlt` test file |
| `ReadNotebook` / `WriteNotebook` | `.nb` **files on disk** — not the live notebook |

## Shaping output so you can read it

Results come back as `Out[n]= …` text. Two habits make this much less painful.

**Use `InputForm` for anything structural.** Without it you get a typeset
rendering that is lossy and hard to read back:

```wolfram
ToString[Solve[x^3 - 6 x^2 + 11 x - 6 == 0, x], InputForm]
```

**Label multiple results instead of returning a bare list.** Compare a nested
list of six things you then have to count through, with:

```wolfram
Column[{
  "integral: " <> ToString[Integrate[Sqrt[Tan[x]], x], InputForm],
  "sum:      " <> ToString[Sum[1/n^2, {n, 1, Infinity}], InputForm]
}]
```

For associations, `Dataset` renders as a table but `InputForm` is usually easier
to quote back to the user.

## Images come back visually

`Plot`, `Rasterize`, `Image`, `NBCellImage` and anything else producing graphics
return an actual picture into your context. Use it to **check your own work** —
render the thing and look at it before telling the user it's right. A plot with
a mislabelled axis or an empty range is obvious visually and invisible in a text
result.

Keep `ImageSize` modest (200–400) unless detail matters.

## Sessions

Every call returns a session id. Pass it back as `session` to continue in the
same kernel context — definitions, `$Line`, loaded packages all persist. Omit it
and you get a fresh context.

Note that separate sessions may share one OS process; they are separate
*contexts* (`Sessions\`<id>\``), not separate kernels. That matters for the
shadowing problem below.

## Loading a package and using it are two calls

The entire evaluation is parsed before any of it runs. So in

```wolfram
Get["thing.wl"]; MyFunction[]     (* broken *)
```

`MyFunction` is resolved at parse time, before `Get` has had a chance to define
it — it binds to an empty symbol in the current context, and the call silently
returns unevaluated. Nothing errors; you just get your own input echoed back.

Load in one call, use in the next. If you already tripped it, `Remove` the
shadow symbols or start a fresh session.

Package authors can defuse this by defining entry points directly into the
context the caller will be in — that is why `LiveNBServer.wl` puts
`LiveNBStart` in `Global\`` rather than exporting it.

## Re-`Get` after editing a package stacks definitions

`Get` re-runs `SetDelayed`, which **adds** a downvalue unless the pattern is
byte-identical. So if you edit a function's signature and reload the file, both
definitions now exist, and Wolfram dispatches to whichever pattern matches
first — usually the older, more specific one. Your new code is unreachable and
appears to do nothing at all, with no error.

This bites hard here because MCP sessions share one OS process: package
contexts are global to that process, so definitions accumulate across every
session that ever loaded an older version of the file.

Diagnose it with `Length[DownValues[f]]` — more than you wrote is the tell:

```wolfram
First /@ DownValues[LiveNB`NBEvalCell]
(* three patterns where the file only defines one *)
```

Packages you expect to reload should clear themselves on load:

```wolfram
BeginPackage["MyPkg`"];
ClearAll[PublicA, PublicB];      (* before the usage messages *)
Begin["`Private`"];
ClearAll["MyPkg`Private`*"];
```

If the package keeps state that must survive a reload — a task handle, an open
connection — exclude it from the clear and initialise it with
`If[!ValueQ[$x], $x = ...]`. `LiveNBServer.wl` does both, for exactly that
reason.

## Timeouts

The default limit is 60 seconds and it is enforced per call, so batching several
slow things into one evaluation is the usual way to hit it by accident. Pass
`timeConstraint` (seconds) for heavy work.

A call that exceeds the limit isn't lost — it moves to the background and
notifies you when it finishes.

First use of `\[FreeformPrompt]` or entity data in a session pays a network
round trip; afterwards it's cached and fast.

## Curated data and natural language

`\[FreeformPrompt]["…"]` is the equivalent of ctrl-= in a notebook. It is the
right way to produce `Quantity`, `Entity`, `EntityClass` values rather than
guessing their canonical names:

```wolfram
\[FreeformPrompt]["France population"]      (* Quantity[66438822, "People"] *)
\[FreeformPrompt]["123 terawatt hours"]
ColorNegate[\[FreeformPrompt]["picture of a cat"]]
```

The argument must be a **literal string** — it is interpreted before evaluation,
so it cannot be assembled at runtime. It also prints how it interpreted the
query, which is worth reading; ambiguous phrasings resolve in surprising ways.

## WolframLanguageContext

The evaluator's own description asks you to search context before writing code,
and it is good advice for unfamiliar corners of the language — it covers the
function repository and data repository, not just core docs. Write the query as
a description of what you're trying to do, not as keywords. Skip it for routine
work you already know.

## CodeInspector

Useful before handing over a `.wl` file. Be aware that `ReturnAmbiguous` fires
on every `Return` inside a `Module`, which is idiomatic and fine — exclude that
tag or you will drown in it:

```
tagExclusions: "ReturnAmbiguous"
severityExclusions: "Formatting,Scoping,Remark"
```

`GlobalSymbol` warnings are worth a second look but are sometimes deliberate.
