(* ::Package:: *)

(*  LiveNBServer.wl
    -------------------------------------------------------------------
    Runs INSIDE the Wolfram front end's kernel, so it has $Notebooks and
    can touch the live notebook.  Exposes ONE bound notebook to external
    headless kernels through an atomic file mailbox, guarded by a random
    per-session token.

    Transport note: this deliberately avoids sockets.  SocketOpen with
    "ZMQ_REP" segfaults the kernel in this 15.0.1 install, and the server
    side runs in the user's live session, so a polled mailbox is the safe
    choice.  Requests are written by the client as req-<id>.wxf and picked
    up by a scheduled task every $pollInterval seconds.

    From a cell in the notebook you want the agent to drive:

        Get["C:/Users/ifree/.claude/skills/mathematica/scripts/LiveNBServer.wl"];
        LiveNBStart[]
*)

(*  The four entry points live in Global` on purpose.  A notebook parses a
    whole cell before evaluating it, so in

        Get["...LiveNBServer.wl"]; LiveNBStart[]

    the symbol LiveNBStart is created in Global` at parse time, before Get
    runs.  Had the package exported it from LiveNB`Server`, that parsed
    reference would point at an empty Global` symbol and the cell would
    silently echo back unevaluated.  Defining into Global` means Get fills
    in the very symbol the cell already refers to.  Internals stay private. *)

BeginPackage["LiveNB`Server`"];

Global`LiveNBStart::usage  = "LiveNBStart[] binds the evaluating notebook and starts the bridge.";
Global`LiveNBStop::usage   = "LiveNBStop[] stops the bridge and clears its mailbox.";
Global`LiveNBBind::usage   = "LiveNBBind[] rebinds to the evaluating notebook; LiveNBBind[nb] or LiveNBBind[\"title substring\"] binds to another one.";
Global`LiveNBStatus::usage = "LiveNBStatus[] reports what the bridge is bound to.";

Begin["`Private`"];

(*  Get *adds* a downvalue unless the pattern is byte-identical, so reloading
    after a signature change leaves the old definition in place and WL
    dispatches to it - the new code then appears to do nothing at all.  Clear
    the function definitions on load.

    But leave anything named $... alone: $task is the only handle to a running
    poller, and ScheduledTasks[] cannot find it again if we drop it.  Losing it
    orphans a task that then polls forever.  *)
Scan[ClearAll,
    Select[Names["LiveNB`Server`Private`*"],
        StringFreeQ[Last @ StringSplit[#, "`"], "$"] &]];

Global`LiveNBStart[opts___]        := start[opts];
Global`LiveNBStop[]                := stop[];
Global`LiveNBBind[args___]         := bind[args];
Global`LiveNBStatus[]              := status[];

$root         = FileNameJoin[{$UserBaseDirectory, "ApplicationData", "LiveNB"}];
$endpointFile = FileNameJoin[{$root, "endpoint.json"}];
$mailbox      = FileNameJoin[{$root, "mailbox"}];

(*  Conditional, so that re-Get-ing this file while a bridge is running does
    not drop the handle to the live poller.  A plain assignment would orphan
    it: RemoveScheduledTask needs the task object itself, and ScheduledTasks[]
    returns {} in 15.0.1 even with a task demonstrably running, so an orphan
    could never be found again and would poll forever.  *)
If[!ValueQ[$task],      $task      = None];
If[!ValueQ[$token],     $token     = None];
If[!ValueQ[$nb],        $nb        = None];
If[!ValueQ[$lastSweep], $lastSweep = 0];

$maxEvalSeconds = 120;
$codeStyles     = {"Input", "Code", "Program"};

(* ---------- lifecycle ---------------------------------------------- *)

Options[start] = {"Notebook" -> Automatic, "PollInterval" -> 0.1};
Options[Global`LiveNBStart] = Options[start];

start[OptionsPattern[]] :=
    Module[{nb},
        (* resolve the notebook before stopping anything, so a failed start
           from a headless kernel can't clobber a working bridge *)
        nb = Replace[OptionValue["Notebook"], Automatic :> currentNotebook[]];
        If[!MatchQ[nb, _NotebookObject],
            Return @ Failure["NoNotebook",
                <|"MessageTemplate" -> "No notebook available to bind."|>]];
        stop[];
        $nb    = nb;
        $token = IntegerString[RandomInteger[{16^19, 16^20 - 1}], 16];
        If[!DirectoryQ[$mailbox], CreateDirectory[$mailbox, CreateIntermediateDirectories -> True]];
        clearMailbox[];
        (* bare interval, NOT {interval}: RunScheduledTask[expr, {t}] means
           "run once, t seconds from now" ({t, 1}), whereas a bare number
           means "every t seconds forever" ({t, Infinity}) *)
        $task = RunScheduledTask[poll[], OptionValue["PollInterval"]];
        writeEndpoint[];
        status[]
    ];

stop[] := (
    If[$task =!= None, Quiet @ RemoveScheduledTask[$task]];
    $task = None;
    $token = None;
    If[FileExistsQ[$endpointFile], Quiet @ DeleteFile[$endpointFile]];
    clearMailbox[];
    "LiveNB bridge stopped."
);

clearMailbox[] := If[DirectoryQ[$mailbox], Quiet[DeleteFile /@ FileNames["*", $mailbox]]];

bind[] := bind[currentNotebook[]];

bind[nb_NotebookObject] := ($nb = nb; writeEndpoint[]; status[]);

bind[pattern_String] :=
    Module[{match},
        match = SelectFirst[Notebooks[],
            StringContainsQ[windowTitle[#], pattern, IgnoreCase -> True] &];
        If[MatchQ[match, _NotebookObject],
            bind[match],
            Failure["NoMatch",
                <|"MessageTemplate" -> "No open notebook title contains \"" <> pattern <> "\"."|>]]];

status[] :=
    If[$task === None,
        "LiveNB bridge: stopped.",
        Column[{
            "LiveNB bridge running (file mailbox).",
            "bound notebook: " <> windowTitle[$nb],
            "cells: " <> ToString @ Length @ Quiet @ Cells[$nb],
            "mailbox: " <> $mailbox}]];

currentNotebook[] :=
    Module[{nb = Quiet @ EvaluationNotebook[]},
        If[MatchQ[nb, _NotebookObject], nb, Quiet @ SelectedNotebook[]]];

windowTitle[nb_] := ToString @ Quiet @ AbsoluteCurrentValue[nb, WindowTitle];

writeEndpoint[] :=
    (If[!DirectoryQ[$root], CreateDirectory[$root, CreateIntermediateDirectories -> True]];
     Export[$endpointFile,
        <|"mailbox"  -> $mailbox,
          "token"    -> $token,
          "pid"      -> $ProcessID,
          "notebook" -> windowTitle[$nb]|>, "JSON"]);

(* ---------- transport ----------------------------------------------- *)

poll[] :=
    Quiet @ Check[
        Module[{files = FileNames["req-*.wxf", $mailbox]},
            If[files =!= {}, handleFile /@ Take[files, UpTo[4]]];
            sweep[]],
        Null];

(*  A client that gives up on a slow call deletes its request, but if we had
    already picked it up our reply has nobody to collect it.  Without this the
    mailbox accumulates orphaned replies for the life of the session.  *)
sweep[] :=
    Module[{now = AbsoluteTime[], stale},
        If[now - $lastSweep < 60, Return[Null]];
        $lastSweep = now;
        stale = Select[FileNames[{"resp-*.wxf", "*.part"}, $mailbox],
            TrueQ[Quiet[now - AbsoluteTime[FileDate[#]]] > 300] &];
        Quiet[DeleteFile /@ stale]];

handleFile[f_String] :=
    Module[{ba, req, id},
        ba = Quiet @ ReadByteArray[f];
        Quiet @ DeleteFile[f];
        req = If[ByteArrayQ[ba], Quiet @ Check[BinaryDeserialize[ba], $Failed], $Failed];
        If[!AssociationQ[req], Return[Null]];
        id = req["id"];
        If[!StringQ[id], Return[Null]];
        writeAtomic[FileNameJoin[{$mailbox, "resp-" <> id <> ".wxf"}],
            safeSerialize @ respondTo[req]]];

(*  The request file is deleted before the work starts, so if an exception
    escaped we would never reply and the client could only time out.  Catch
    Throw and Abort so there is always an answer.  Deliberately NOT Check:
    messages are normal here and dispatch reports them in "messages".  *)
respondTo[req_] :=
    CheckAbort[
        Catch[
            If[req["token"] =!= $token,
                fail["BadToken", "Token mismatch \[LongDash] re-run LiveNBStart[] and reload the client."],
                dispatch[req]],
            _,
            Function[{val, tag},
                fail["UncaughtThrow",
                    "A Throw with tag " <> ToString[tag] <> " escaped this request."]]],
        fail["Aborted", "The evaluation was aborted in the notebook's kernel."]];

writeAtomic[path_String, ba_] :=
    Module[{tmp = path <> ".part", s},
        s = OpenWrite[tmp, BinaryFormat -> True];
        BinaryWrite[s, ba];
        Close[s];
        RenameFile[tmp, path]];

fail[tag_, msg_] := <|"ok" -> False, "error" -> tag, "message" -> msg|>;

safeSerialize[expr_] :=
    Module[{b = Quiet @ Check[BinarySerialize[expr], $Failed]},
        If[ByteArrayQ[b], b,
            BinarySerialize @ fail["Unserializable", ToString[Short[expr, 5], InputForm]]]];

$api = {"info", "read", "readCell", "cellImage", "selection",
        "writeCell", "insertAfter", "append", "deleteCell", "evalCell", "save"};

dispatch[req_] :=
    Module[{res, msgs},
        Block[{$MessageList = {}},
            res = Switch[req["op"],
                "call",
                    With[{fn = req["fn"], args = req["args"]},
                        If[MemberQ[$api, fn] && ListQ[args],
                            Apply[Symbol["LiveNB`Server`Private`" <> fn], args],
                            fail["UnknownFunction", ToString[fn]]]],
                "eval",
                    (* bound it: a runaway NBEval would otherwise wedge the
                       poller, and with it the whole bridge, indefinitely *)
                    Block[{$Context = "Global`", $ContextPath = {"Global`", "System`"}},
                        TimeConstrained[ToExpression[req["code"]], $maxEvalSeconds,
                            fail["EvalTimeout", "Evaluation exceeded " <>
                                ToString[$maxEvalSeconds] <> "s and was stopped."]]],
                _, fail["UnknownOp", ToString @ req["op"]]];
            msgs = ToString /@ $MessageList];
        If[AssociationQ[res] && res["ok"] === False,
            res,
            <|"ok" -> True, "result" -> res, "messages" -> msgs|>]];

(* ---------- notebook API --------------------------------------------- *)

(*  Only call the notebook gone when the front end positively says so.  If
    Notebooks[] itself fails - no front end reachable from this evaluation -
    trust $nb rather than reporting a misleading "notebook closed".  *)
nbTarget[] :=
    Module[{all},
        If[!MatchQ[$nb, _NotebookObject], Return[$Failed]];
        all = Quiet @ Check[Notebooks[], $Failed];
        If[ListQ[all] && !MemberQ[all, $nb], $Failed, $nb]];

gone[] := fail["NotebookGone", "The bound notebook is no longer open. Re-run LiveNBStart[]."];

(*  Cells can be addressed two ways.  An integer is the visual position, which
    is convenient but shifts the moment the user inserts or deletes anything.
    A string is the cell's own stable id, handed out by read/readCell/selection:
    it follows the cell around, and if the cell is gone the call fails cleanly
    instead of hitting whatever has since moved into that slot.  Prefer ids for
    anything destructive.  *)
cellRef[co_CellObject] := First[co];

resolve[cos_List, spec_] :=
    Which[
        IntegerQ[spec],
            If[1 <= spec <= Length[cos], {cos[[spec]], spec}, $Failed],
        StringQ[spec],
            With[{p = FirstPosition[cos, CellObject[spec, ___], Missing[], {1}]},
                If[MissingQ[p], $Failed, {cos[[First @ p]], First @ p}]],
        True, $Failed];

badRef[spec_, n_] :=
    If[StringQ[spec],
        fail["CellGone",
            "No cell with id " <> spec <> " \[LongDash] it was deleted, or belongs to \
a different notebook. Re-read the notebook to get current ids."],
        fail["BadIndex",
            "Cell " <> ToString[spec] <> " is out of range (1.." <> ToString[n] <> ")."]];

(*  id of whatever NotebookWrite[..., All] just left selected, so a caller can
    address the cell it created without re-reading the whole notebook *)
justWritten[nb_] :=
    With[{s = Replace[Quiet @ Check[SelectedCells[nb], {}], Except[_List] -> {}]},
        If[MatchQ[s, {_CellObject, ___}], cellRef[First @ s], None]];

info[] :=
    Module[{nb = nbTarget[]},
        If[nb === $Failed, Return @ gone[]];
        <|"title" -> windowTitle[nb],
          "path"  -> Replace[Quiet @ NotebookFileName[nb], Except[_String] -> None],
          "cellCount" -> Length @ Cells[nb]|>];

cellStyle[Cell[_, s_String, ___]] := s;
cellStyle[_] := "Unknown";

cellText[cell_Cell] :=
    Module[{r = Quiet @ Check[FrontEndExecute @ FrontEnd`ExportPacket[cell, "InputText"], $Failed]},
        Which[
            MatchQ[r, {_String, ___}],  First[r],
            StringQ[r],                 r,
            StringQ[First[cell, ""]],   First[cell],
            True,                       ToString[Short[First[cell, ""], 4], InputForm]]];
cellText[_] := "";

truncate[s_String, n_Integer] :=
    If[StringLength[s] <= n, s,
        StringTake[s, n] <> "\n\[Ellipsis] (" <> ToString[StringLength[s] - n] <>
        " more chars \[LongDash] use NBReadCell)"];

readCells[cos_List] :=
    If[cos === {}, {},
        Module[{r = Quiet @ NotebookRead[cos]},
            If[ListQ[r] && Length[r] === Length[cos], r, NotebookRead /@ cos]]];

read[maxChars_: 400] :=
    Module[{nb = nbTarget[], cos},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        <|"notebook" -> info[],
          "cells" -> MapThread[
              Function[{idx, co, cell},
                  With[{t = cellText[cell]},
                      <|"i" -> idx, "id" -> cellRef[co], "style" -> cellStyle[cell],
                        "chars" -> StringLength[t], "text" -> truncate[t, maxChars]|>]],
              {Range @ Length @ cos, cos, readCells[cos]}]|>];

readCell[spec : (_Integer | _String)] :=
    Module[{nb = nbTarget[], cos, r},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        r = resolve[cos, spec];
        If[r === $Failed, Return @ badRef[spec, Length[cos]]];
        With[{cell = NotebookRead[First @ r]},
            <|"i" -> Last[r], "id" -> cellRef[First @ r],
              "style" -> cellStyle[cell], "text" -> cellText[cell]|>]];

cellImage[spec : (_Integer | _String)] :=
    Module[{nb = nbTarget[], cos, r},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        r = resolve[cos, spec];
        If[r === $Failed, Return @ badRef[spec, Length[cos]]];
        Quiet @ Check[
            Rasterize[NotebookRead[First @ r], ImageResolution -> 96],
            fail["RasterizeFailed", "Could not rasterize cell " <> ToString[spec] <> "."]]];

selection[] :=
    Module[{nb = nbTarget[], cos, sel, idx},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        sel = Replace[Quiet @ Check[SelectedCells[nb], {}], Except[_List] -> {}];
        (* per-cell, with a fallback, so idx always lines up with sel *)
        idx = With[{p = FirstPosition[cos, #, Missing[], {1}]},
                  If[MissingQ[p], 0, First @ p]] & /@ sel;
        <|"indices" -> idx,
          "cells" -> If[sel === {}, {},
              MapThread[
                  <|"i" -> #1, "id" -> cellRef[#2],
                    "style" -> cellStyle[#3], "text" -> cellText[#3]|> &,
                  {idx, sel, readCells[sel]}]]|>];

(*  Returns {cell, parsedQ}.  For a code style we ask the front end to boxify
    the text so it looks like code the user typed; if that fails we still
    write a plain text cell, but the caller reports parsed -> False rather
    than silently degrading.  *)
makeCellQ[text_String, style_String] :=
    Module[{boxes},
        If[MemberQ[$codeStyles, style],
            boxes = parseBoxes[text];
            If[boxes =!= $Failed,
                {Cell[BoxData[boxes], style], True},
                {Cell[text, style], False}],
            {Cell[text, style], True}]];

parseBoxes[text_String] :=
    Module[{r = Quiet @ Check[
        MathLink`CallFrontEnd @ FrontEnd`UndocumentedTestFEParserPacket[text, True], $Failed]},
        Which[
            MatchQ[r, {Cell[BoxData[_], ___], ___}], r[[1, 1, 1]],
            MatchQ[r, {BoxData[_], ___}],            r[[1, 1]],
            MatchQ[r, Cell[BoxData[_], ___]],        r[[1, 1]],
            MatchQ[r, BoxData[_]],                   r[[1]],
            True, $Failed]];

(*  Destructive calls echo back what was there.  Cell indices are resolved
    fresh on every call, so anything the user edits between the agent's read
    and its write shifts them; returning the replaced content lets the caller
    notice it clobbered the wrong cell, and recover the text.  *)
former[co_] := Module[{c = NotebookRead[co]},
    <|"style" -> cellStyle[c], "text" -> truncate[cellText[c], 200]|>];

writeCell[spec : (_Integer | _String), style_String, text_String] :=
    Module[{nb = nbTarget[], cos, r, cell, parsed, prev},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        r = resolve[cos, spec];
        If[r === $Failed, Return @ badRef[spec, Length[cos]]];
        prev = former[First @ r];
        {cell, parsed} = makeCellQ[text, style];
        NotebookWrite[First @ r, cell, All];
        <|"wrote" -> Last[r], "id" -> justWritten[nb],
          "style" -> style, "parsed" -> parsed, "replaced" -> prev|>];

insertAfter[spec : (_Integer | _String), style_String, text_String] :=
    Module[{nb = nbTarget[], cos, r, cell, parsed},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        If[spec === 0,
            SelectionMove[nb, Before, Notebook],
            r = resolve[cos, spec];
            If[r === $Failed, Return @ badRef[spec, Length[cos]]];
            SelectionMove[First @ r, After, Cell]];
        {cell, parsed} = makeCellQ[text, style];
        NotebookWrite[nb, cell, All];
        <|"insertedAfter" -> spec, "id" -> justWritten[nb], "parsed" -> parsed|>];

append[style_String, text_String] :=
    Module[{nb = nbTarget[], cos, cell, parsed},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        If[cos === {},
            SelectionMove[nb, Before, Notebook],
            SelectionMove[Last[cos], After, Cell]];
        {cell, parsed} = makeCellQ[text, style];
        NotebookWrite[nb, cell, All];
        <|"appended" -> Length[cos] + 1, "id" -> justWritten[nb], "parsed" -> parsed|>];

deleteCell[spec : (_Integer | _String)] :=
    Module[{nb = nbTarget[], cos, r, prev},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        r = resolve[cos, spec];
        If[r === $Failed, Return @ badRef[spec, Length[cos]]];
        prev = former[First @ r];
        NotebookDelete[First @ r];
        <|"deleted" -> Last[r], "was" -> prev|>];

(*  This only *queues* the evaluation - it cannot wait for it. The kernel that
    would do the waiting is the same kernel the front end must call to run the
    cell, so waiting here deadlocks. The client waits instead; see
    NBEvalCell's "Wait" option. The style is reported back so the client knows
    whether to expect the evaluation to happen at all.  *)
evalCell[spec : (_Integer | _String)] :=
    Module[{nb = nbTarget[], cos, r},
        If[nb === $Failed, Return @ gone[]];
        cos = Cells[nb];
        r = resolve[cos, spec];
        If[r === $Failed, Return @ badRef[spec, Length[cos]]];
        With[{style = cellStyle @ NotebookRead[First @ r]},
            SelectionMove[First @ r, All, Cell];
            FrontEndTokenExecute[nb, "EvaluateCells"];
            <|"queued" -> Last[r], "style" -> style|>]];

(*  Never call NotebookSave on a notebook with no file.  It opens a modal Save
    dialog in the front end and blocks until the user answers it - and since
    this runs inside the poller, that would freeze the whole bridge behind a
    dialog the agent cannot see or dismiss.  *)
save[] :=
    Module[{nb = nbTarget[], path},
        If[nb === $Failed, Return @ gone[]];
        path = Quiet @ NotebookFileName[nb];
        If[!StringQ[path],
            Return @ fail["NotebookNeverSaved",
                "This notebook has no file yet, so saving would open a modal dialog and \
block the bridge. Ask the user to save it once by hand first."]];
        NotebookSave[nb];
        <|"saved" -> path|>];

End[];
EndPackage[];