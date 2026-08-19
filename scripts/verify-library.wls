#!/usr/bin/env wolframscript
(*  Runs every library/tests/*.wlt file and prints a summary.  This is what
    lets a later session trust a library entry it has never watched work.

        wolframscript -file scripts/verify-library.wls

    Exits 1 if any test failed, so it can be used as a check.
    Entries whose header says kernel: frontend are skipped here unless a front
    end is available, since they cannot pass in a headless kernel.
*)

$skill   = ParentDirectory[DirectoryName[$InputFileName]];
$library = FileNameJoin[{$skill, "library"}];
$tests   = FileNameJoin[{$library, "tests"}];

needsFrontEnd[slug_String] :=
    Module[{text = Quiet @ Import[FileNameJoin[{$library, slug <> ".wl"}], "Text"]},
        StringQ[text] &&
        StringContainsQ[text, RegularExpression["(?i)kernel:\\s*frontend"]]];

Module[{files, results, failed = 0, skipped = {}},
    files = Sort @ FileNames["*.wlt", $tests];
    If[files === {},
        Print["No tests in ", $tests, " yet."];
        Exit[0]];

    results = Table[
        Module[{slug = FileBaseName[f], report},
            If[needsFrontEnd[slug] && !$Notebooks,
                AppendTo[skipped, slug];
                {slug, "skipped (needs a front end)", 0, 0},
                report = Quiet @ Check[TestReport[f], $Failed];
                If[report === $Failed,
                    failed++; {slug, "ERROR could not run", 0, 0},
                    With[{ok = report["TestsSucceededCount"],
                          no = report["TestsFailedCount"]},
                        failed += no;
                        {slug, If[no === 0, "pass", "FAIL"], ok, no}]]]],
        {f, files}];

    Print["\n", StringPadRight["entry", 32], StringPadRight["result", 26], "passed  failed"];
    Print[StringRepeat["-", 72]];
    Do[Print[
        StringPadRight[r[[1]], 32], StringPadRight[ToString @ r[[2]], 26],
        StringPadLeft[ToString @ r[[3]], 6], StringPadLeft[ToString @ r[[4]], 8]],
       {r, results}];
    Print[StringRepeat["-", 72]];
    Print[Length[files], " file(s), ", failed, " failing test(s)",
          If[skipped === {}, "", ", " <> ToString[Length[skipped]] <> " skipped"]];
    Exit[If[failed > 0, 1, 0]];
];
