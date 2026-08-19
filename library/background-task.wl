(* ::Package:: *)

(* ::Library::
name:     background-task
summary:  Repeating background tasks that survive this build's broken ScheduledTasks[]
tags:     scheduling, background, workaround
kernel:   any
provides: StartPoller, StopPoller, ActivePollers, StopAllPollers
verified: 15.0.1 2026-08-20
:: *)

(*  Two traps make raw RunScheduledTask unreliable on Wolfram 15.0.1:

      1. RunScheduledTask[expr, {t}] means "once, t seconds from now", not
         "every t seconds".  The braced form is easy to write by accident and
         looks like it works, because the task does fire once at startup.

      2. ScheduledTasks[] returns {} even with a task demonstrably running, so
         a task whose handle you dropped can never be found or stopped again.

    This wrapper always uses the repeating form and keeps its own registry, so
    handles survive re-loading the package and you can always stop what you
    started.  See reference/quirks.md for the evidence behind both. *)

BeginPackage["WLib`BackgroundTask`"];

(* Get adds downvalues rather than replacing them, so a reload after any
   signature change would leave the old definition winning.  Clear the
   functions - but not $pollers, which holds the only usable handles. *)
ClearAll[StartPoller, StopPoller, ActivePollers, StopAllPollers];

StartPoller::usage    ="StartPoller[expr, dt] evaluates expr every dt seconds and returns a name to stop it with. expr is not evaluated when you call this.";
StopPoller::usage     = "StopPoller[name] stops the poller and forgets it.";
ActivePollers::usage  = "ActivePollers[] lists the pollers this package started, since ScheduledTasks[] cannot be trusted here.";
StopAllPollers::usage = "StopAllPollers[] stops every poller this package started.";

Begin["`Private`"];

(* conditional, so re-Get-ing never drops handles to running tasks *)
If[!ValueQ[$pollers], $pollers = <||>];
If[!ValueQ[$counter], $counter = 0];

SetAttributes[StartPoller, HoldFirst];

StartPoller[expr_, dt_?NumericQ] :=
    Module[{name},
        If[!TrueQ[dt > 0],
            Return @ Failure["BadInterval",
                <|"MessageTemplate" -> "The interval must be a positive number of seconds."|>]];
        $counter += 1;
        name = "poller-" <> ToString[$counter];
        (* bare dt, never {dt} - see trap 1 above *)
        $pollers[name] = RunScheduledTask[expr, dt];
        name];

StopPoller[name_String] :=
    If[KeyExistsQ[$pollers, name],
        Quiet @ RemoveScheduledTask[$pollers[name]];
        $pollers = KeyDrop[$pollers, name];
        name,
        Failure["NoSuchPoller",
            <|"MessageTemplate" -> "No poller named " <> name <> " is registered."|>]];

ActivePollers[] := Keys[$pollers];

StopAllPollers[] := (StopPoller /@ Keys[$pollers]; Length[$pollers]);

End[];
EndPackage[];
