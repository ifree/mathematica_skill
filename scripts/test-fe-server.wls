#!/usr/bin/env wolframscript
(* Full end-to-end test: runs the REAL LiveNBServer against a real (hidden,
   throwaway) front end, serviced by the server's own scheduled task.

   The one harness-only deviation: a scheduled task's evaluation does not
   inherit the script's Developer`UseFrontEnd dynamic scope, so poll[] would
   see no front end and every notebook call would fail.  Re-wrapping the task
   body in UsingFrontEnd gives it one.  A real notebook session needs no such
   help - that kernel always has a front end. *)

Get["C:/Users/ifree/.claude/skills/mathematica/scripts/LiveNBServer.wl"];

(* isolate onto its own mailbox so a real bridge running in the user's front
   end is not disturbed and the two do not race for the same requests *)
LiveNB`Server`Private`$root =
    FileNameJoin[{$UserBaseDirectory, "ApplicationData", "LiveNBTest"}];
LiveNB`Server`Private`$endpointFile =
    FileNameJoin[{LiveNB`Server`Private`$root, "endpoint.json"}];
LiveNB`Server`Private`$mailbox =
    FileNameJoin[{LiveNB`Server`Private`$root, "mailbox"}];

Developer`UseFrontEnd[
    Module[{nb},
        nb = CreateDocument[{
            Cell["LiveNB FE test", "Title"],
            Cell[BoxData[RowBox[{"1", "+", "1"}]], "Input"],
            Cell["a plain text cell", "Text"],
            Cell[BoxData[RowBox[{"Integrate", "[",
                RowBox[{RowBox[{"Sqrt", "[", "x", "]"}], ",", "x"}], "]"}]], "Input"]},
            Visible -> False];
        Print["nb    = ", nb];
        Print["start = ", LiveNBStart["Notebook" -> nb]];

        RemoveScheduledTask[LiveNB`Server`Private`$task];
        LiveNB`Server`Private`$task =
            RunScheduledTask[UsingFrontEnd[LiveNB`Server`Private`poll[]], 0.1];

        Print["READY"];
        While[True, Pause[0.5]];
    ]
];
