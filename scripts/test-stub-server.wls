#!/usr/bin/env wolframscript
(* Transport smoke test: runs LiveNBServer's real mailbox/dispatch code in a
   headless kernel, with the front-end-dependent notebook API stubbed out. *)

Get["C:/Users/ifree/.claude/skills/mathematica/scripts/LiveNBServer.wl"];

Begin["LiveNB`Server`Private`"];

Clear[nbTarget, info, read, writeCell, cellImage];
nbTarget[] := "FAKE";
info[] := <|"title" -> "stub.nb", "path" -> None, "cellCount" -> 2|>;
read[max_: 400] := <|"notebook" -> info[],
    "cells" -> {<|"i" -> 1, "style" -> "Input", "chars" -> 22,
                  "text" -> truncate["Plot[Sin[x],{x,0,2Pi}]", max]|>,
                <|"i" -> 2, "style" -> "Text", "chars" -> 5, "text" -> "hello"|>}|>;
writeCell[i_Integer, s_String, t_String] := <|"wrote" -> i, "style" -> s, "echo" -> t|>;
cellImage[i_Integer] := Image[Table[Sin[x/6.] Cos[y/6.], {y, 40}, {x, 60}]];

$token = "test-token-abc";
If[!DirectoryQ[$mailbox], CreateDirectory[$mailbox, CreateIntermediateDirectories -> True]];
clearMailbox[];
$task = RunScheduledTask[poll[], {0.1}];
writeEndpoint[];
Print["mailbox: ", $mailbox];
Print["task: ", $task];

End[];

Print["READY"];
While[True, LiveNB`Server`Private`poll[]; Pause[0.1]];