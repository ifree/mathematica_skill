(* ::Package:: *)

(*  LiveNBClient.wl
    -------------------------------------------------------------------
    Loaded into the HEADLESS kernel behind the Wolfram MCP server.
    Talks to LiveNBServer.wl running in the front end's kernel, so the
    agent can read and write the notebook the user actually has open.

        Get["C:/Users/ifree/.claude/skills/mathematica/scripts/LiveNBClient.wl"]
*)

BeginPackage["LiveNB`"];

(*  Reloading must not leave older definitions behind.  Get re-runs SetDelayed,
    which *adds* a downvalue unless the pattern is byte-identical - so editing a
    signature stacks the new definition on top of the old one, and the more
    specific (usually stale) pattern is the one that gets dispatched to.  The
    new code then looks like it silently does nothing.  Clear first.  *)
ClearAll[NBStatus, NBRead, NBReadCell, NBCellImage, NBSelection, NBWrite,
         NBInsert, NBAppend, NBDelete, NBEval, NBEvalCell, NBSave, NBTimeout];

NBStatus::usage    ="NBStatus[] gives the bound notebook's title, path and cell count.";
NBRead::usage      = "NBRead[] gives an outline of every cell; NBRead[n] truncates each cell at n chars.";
NBReadCell::usage  = "NBReadCell[c] gives the full text of cell c, addressed by position or id.";
NBCellImage::usage = "NBCellImage[c] renders cell c as an image.";
NBSelection::usage = "NBSelection[] gives the cells currently selected in the notebook.";
NBWrite::usage     = "NBWrite[c, style, text] replaces cell c and returns the content it replaced.";
NBInsert::usage    = "NBInsert[c, style, text] inserts a new cell after cell c (0 = top of notebook).";
NBAppend::usage    = "NBAppend[style, text] appends a cell at the end.";
NBDelete::usage    = "NBDelete[c] deletes cell c and returns what was deleted.";
NBEval::usage      = "NBEval[\"code\"] evaluates code in the notebook's own kernel, so it sees the notebook's variables.";
NBEvalCell::usage  = "NBEvalCell[c] evaluates cell c in place in the front end and waits for it to finish. Pass \"Wait\" -> False for fire-and-forget, but then do not queue another evaluation until this one has landed.";
NBSave::usage      = "NBSave[] saves the notebook.";
NBTimeout::usage   = "NBTimeout is how many seconds to wait for the front end's kernel to reply.";

Begin["`Private`"];

ClearAll["LiveNB`Private`*"];

$endpointFile = FileNameJoin[{$UserBaseDirectory, "ApplicationData", "LiveNB", "endpoint.json"}];

NBTimeout = 60;

endpoint[] :=
    If[FileExistsQ[$endpointFile],
        Quiet @ Check[Import[$endpointFile, "RawJSON"], $Failed],
        $Failed];

noBridge[] := Failure["NoBridge", <|"MessageTemplate" ->
    "LiveNB bridge is not running. Ask the user to evaluate LiveNBStart[] in the notebook \
they want exposed. If init.m has not been installed, they need the full form: \
Get[\"C:/Users/ifree/.claude/skills/mathematica/scripts/LiveNBServer.wl\"]; LiveNBStart[]"|>];

writeAtomic[path_String, ba_] :=
    Module[{tmp = path <> ".part", s},
        s = OpenWrite[tmp, BinaryFormat -> True];
        BinaryWrite[s, ba];
        Close[s];
        RenameFile[tmp, path]];

request[payload_Association] :=
    Module[{ep, dir, id, reqFile, respFile, t0, ba, res},
        ep = endpoint[];
        If[!AssociationQ[ep], Return @ noBridge[]];
        dir = ep["mailbox"];
        If[!DirectoryQ[dir], Return @ noBridge[]];
        id = IntegerString[RandomInteger[{16^15, 16^16 - 1}], 16];
        reqFile  = FileNameJoin[{dir, "req-"  <> id <> ".wxf"}];
        respFile = FileNameJoin[{dir, "resp-" <> id <> ".wxf"}];
        writeAtomic[reqFile,
            BinarySerialize @ Join[<|"token" -> ep["token"], "id" -> id|>, payload]];
        t0 = AbsoluteTime[];
        While[!FileExistsQ[respFile],
            If[AbsoluteTime[] - t0 > NBTimeout,
                Quiet @ DeleteFile[reqFile];
                Return @ Failure["Timeout", <|"MessageTemplate" ->
                    "No reply within " <> ToString[NBTimeout] <>
                    "s \[LongDash] the notebook's kernel is busy, or the bridge is not running."|>]];
            Pause[0.05]];
        ba = Quiet @ ReadByteArray[respFile];
        Quiet @ DeleteFile[respFile];
        res = If[ByteArrayQ[ba], Quiet @ Check[BinaryDeserialize[ba], $Failed], $Failed];
        Which[
            !AssociationQ[res],          res,
            res["ok"] =!= True,          Failure[Lookup[res, "error", "Error"],
                                             <|"MessageTemplate" -> ToString @ Lookup[res, "message", res]|>],
            res["messages"] === {} ||
              MissingQ[res["messages"]], res["result"],
            True,                        <|"result" -> res["result"], "messages" -> res["messages"]|>]];

call[fn_String, args_List] := request[<|"op" -> "call", "fn" -> fn, "args" -> args|>];

(*  cell is either an integer position or the stable "id" string that NBRead,
    NBReadCell and NBSelection hand out.  Positions shift under the user's
    edits; ids do not, and a dead one fails cleanly.  Use ids for NBWrite and
    NBDelete unless the read that produced them was a moment ago.  *)
NBStatus[]                       := call["info", {}];
NBRead[max_Integer : 400]        := call["read", {max}];
NBReadCell[c : (_Integer | _String)]  := call["readCell", {c}];
NBCellImage[c : (_Integer | _String)] := call["cellImage", {c}];
NBSelection[]                    := call["selection", {}];
NBWrite[c : (_Integer | _String), style_String, text_String]  := call["writeCell", {c, style, text}];
NBInsert[c : (_Integer | _String), style_String, text_String] := call["insertAfter", {c, style, text}];
NBAppend[style_String, text_String]   := call["append", {style, text}];
NBDelete[c : (_Integer | _String)]    := call["deleteCell", {c}];
(*  Waiting is the default, because the failure mode of not waiting is bad and
    silent. FrontEndTokenExecute only queues the evaluation; issuing a second
    one before the first result has been written moves the selection out from
    under the front end, and the output lands in the wrong cell - in the
    user's notebook, with no error anywhere.

    The server cannot do this waiting itself: the kernel that would wait is the
    same kernel the front end must call to run the cell, so it would deadlock.
    That is why it falls to the client.

    $Line is the signal. A front-end evaluation increments it, while NBEval
    does not, because NBEval runs inside the poller rather than through the
    kernel's main loop. Cell count would not work - an expression ending in a
    semicolon produces no output cell at all, yet still counts as evaluated. *)

Options[NBEvalCell] = {"Wait" -> True, "Timeout" -> 60};

NBEvalCell[c : (_Integer | _String), OptionsPattern[]] :=
    Module[{before, queued, t0, line},
        If[!TrueQ[OptionValue["Wait"]], Return @ call["evalCell", {c}]];
        before = NBEval["$Line"];
        queued  = call["evalCell", {c}];
        If[!AssociationQ[queued] || !IntegerQ[before], Return[queued]];
        If[!MemberQ[{"Input", "Code"}, Lookup[queued, "style", ""]],
            Return @ Append[queued,
                "completed" -> "not an evaluatable cell style; nothing was queued"]];
        t0 = AbsoluteTime[];
        While[AbsoluteTime[] - t0 < OptionValue["Timeout"],
            Pause[0.25];
            line = NBEval["$Line"];
            If[IntegerQ[line] && line > before,
                Return @ Append[queued, "completed" -> True]]];
        Append[queued, "completed" -> False]];
NBSave[]                         := call["save", {}];
NBEval[code_String]              := request[<|"op" -> "eval", "code" -> code|>];

End[];
EndPackage[];

(*  A client that parses a whole cell before evaluating it \[LongDash] the MCP
    session kernel does \[LongDash] will already have created NB* symbols in the
    caller's own context by the time this file loads, which then shadow
    LiveNB`.  Drop them so the next evaluation resolves correctly.  Load
    this file in its own evaluation, then use NB* in later ones.  *)
With[{shadows = Names[$Context <> "NB*"]},
    Quiet[Remove /@ shadows]];