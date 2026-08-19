#!/usr/bin/env wolframscript
(*  Patches $UserBaseDirectory/Kernel/init.m so that LiveNBStart[] and friends
    are available in any front-end session without a Get first.

        wolframscript -file scripts/install-init.wls
        wolframscript -file scripts/install-init.wls uninstall

    A --target <path> argument overrides which init.m is edited.  It exists so
    the script can be exercised against a scratch file instead of the real one.

    Three things make this safe to run on an init.m that already has content:

      - it edits only between its own markers, so re-running replaces the block
        rather than stacking copies of it;
      - it backs the file up first, once per run, with a timestamp;
      - what it installs are lazy stubs, not the package itself, so kernel
        startup cost stays at zero.  The stubs clear themselves before loading,
        so a failed Get leaves the symbols undefined rather than recursing.

    This has no effect on the MCP server's kernel, which runs with -noinit.
*)

$server = FileNameJoin[{DirectoryName[$InputFileName], "LiveNBServer.wl"}];
$init   = FileNameJoin[{$UserBaseDirectory, "Kernel", "init.m"}];
$begin  = "(* >>> LiveNB (managed by the mathematica skill) >>> *)";
$end    = "(* <<< LiveNB <<< *)";

block[] := StringJoin[
    $begin, "\n",
    "(* Lazy stubs. The first call clears them, loads the package - which\n",
    "   defines the real LiveNB* functions into Global` - and re-dispatches.\n",
    "   Clearing first means a failed Get leaves the symbols undefined\n",
    "   instead of recursing forever. *)\n",
    "Global`LiveNBLoad[] := (\n",
    "    Clear[Global`LiveNBStart, Global`LiveNBStop, Global`LiveNBBind,\n",
    "          Global`LiveNBStatus, Global`LiveNBLoad];\n",
    "    Get[", ToString[$server, InputForm], "]);\n",
    "Global`LiveNBStart[a___]  := (Global`LiveNBLoad[]; Global`LiveNBStart[a]);\n",
    "Global`LiveNBStop[a___]   := (Global`LiveNBLoad[]; Global`LiveNBStop[a]);\n",
    "Global`LiveNBBind[a___]   := (Global`LiveNBLoad[]; Global`LiveNBBind[a]);\n",
    "Global`LiveNBStatus[a___] := (Global`LiveNBLoad[]; Global`LiveNBStatus[a]);\n",
    $end];

backup[] :=
    If[FileExistsQ[$init],
        Module[{dest = $init <> ".bak-" <>
            StringReplace[DateString["ISODateTime"], {":" -> "", "-" -> ""}]},
            CopyFile[$init, dest];
            Print["backed up -> ", dest];
            dest],
        None];

hasBlock[text_String] := StringContainsQ[text, $begin] && StringContainsQ[text, $end];

stripBlock[text_String] :=
    StringTrim @ StringReplace[text, $begin ~~ Shortest[___] ~~ $end -> ""];

Module[{args, mode, old, new, target},
    args = Rest[$ScriptCommandLine];
    mode = If[MemberQ[ToLowerCase /@ args, "uninstall"], "uninstall", "install"];
    target = Replace[FirstPosition[args, "--target", None, {1}],
        {{i_} :> Lookup[Association @ MapIndexed[First[#2] -> #1 &, args], i + 1, None],
         _ -> None}];
    If[StringQ[target], $init = target];

    If[mode === "install" && !FileExistsQ[$server],
        Print["ERROR: cannot find ", $server]; Exit[1]];

    If[!DirectoryQ[DirectoryName[$init]],
        CreateDirectory[DirectoryName[$init], CreateIntermediateDirectories -> True]];

    old = If[FileExistsQ[$init], Import[$init, "Text"], ""];

    If[mode === "uninstall",
        If[!hasBlock[old],
            Print["nothing to remove - no LiveNB block in ", $init]; Exit[0]];
        backup[];
        Export[$init, stripBlock[old] <> "\n", "Text"];
        Print["removed the LiveNB block from ", $init];
        Exit[0]];

    backup[];
    new = If[hasBlock[old],
        StringReplace[old, $begin ~~ Shortest[___] ~~ $end -> block[]],
        StringTrim[old] <> If[StringTrim[old] === "", "", "\n\n"] <> block[] <> "\n"];
    Export[$init, new, "Text"];

    Print[If[hasBlock[old], "updated", "installed"], " the LiveNB block in ", $init];
    Print["loads from: ", $server];
    Print["Takes effect in the next kernel. Restart the kernel (Evaluation > Quit Kernel)"];
    Print["or open Mathematica again, then just evaluate: LiveNBStart[]"];
];
