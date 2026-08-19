(* Tests for library/background-task.wl *)

Get["C:/Users/ifree/.claude/skills/mathematica/library/background-task.wl"];

(* a poller actually repeats - the whole point, given RunScheduledTask[e,{t}] does not *)
VerificationTest[
    Module[{n = 0, p, first},
        p = WLib`BackgroundTask`StartPoller[n += 1, 0.1];
        Pause[1.2];
        first = n;
        WLib`BackgroundTask`StopPoller[p];
        first > 3],
    True,
    TestID -> "poller-repeats"
];

(* stopping really stops it, since ScheduledTasks[] cannot tell us *)
VerificationTest[
    Module[{n = 0, p, atStop},
        p = WLib`BackgroundTask`StartPoller[n += 1, 0.1];
        Pause[0.5];
        WLib`BackgroundTask`StopPoller[p];
        atStop = n;
        Pause[0.7];
        n === atStop],
    True,
    TestID -> "stop-halts-poller"
];

(* the registry is our only way to enumerate, so it must stay accurate *)
VerificationTest[
    Module[{p, during, after},
        p = WLib`BackgroundTask`StartPoller[Null, 5];
        during = MemberQ[WLib`BackgroundTask`ActivePollers[], p];
        WLib`BackgroundTask`StopPoller[p];
        after = MemberQ[WLib`BackgroundTask`ActivePollers[], p];
        {during, after}],
    {True, False},
    TestID -> "registry-tracks-lifecycle"
];

VerificationTest[
    Head @ WLib`BackgroundTask`StartPoller[Null, -1],
    Failure,
    TestID -> "rejects-non-positive-interval"
];

VerificationTest[
    Head @ WLib`BackgroundTask`StopPoller["poller-does-not-exist"],
    Failure,
    TestID -> "unknown-poller-is-a-failure"
];
