# Animation

Things that move - a gauge filling, a list gliding to a new line, a
button fading into its pressed look, a ring of dots going round - all run
on one clock: `motion.library`, in the ROM. This guide is how that clock
works, how a program moves something on it, and how a gadget does.

`C:test/Motion WINDOW` shows most of it at once: seven curves side by
side on one timeline, a gauge, a spinner and a button that fades.

## The clock

```zig
const motion = sdk.motion;
const MotionBase = sdk.interface.motion.MotionBase;

const lib = sys.OpenLibrary(motion.MOTIONNAME, 1) orelse return;
defer sys.CloseLibrary(lib);
const mb: *MotionBase = @ptrCast(lib);
```

One task runs everything that is due: every animation and every timer of
every program. It is made the first time something is due, at priority
10 - above programs, below input.device and intuition's input task, so a
late step stutters rather than the pointer - and it keeps one
`timer.device` request out only while something is due. While nothing
moves it sleeps and costs nothing.

A step is worked out from the time since the start, not counted: a step
that comes late lands further along, and an animation still ends when it
should.

Everything on the clock belongs to the task that made it. A task that
ends without deleting what it made has it taken off the clock as it ends
(an exec task end hook), so no hook is ever called into a program that
has gone.

## Curves

How a value goes from its start to its end is a curve on the progress
from 0 to 1, in 16.16 fixed point: `MOTION_ONE` (65536) is 1.0. Every
curve starts at exactly 0 and ends at exactly `MOTION_ONE`.

| Curve | |
|---|---|
| `EASE_LINEAR` | the same speed all the way |
| `EASE_IN` | slow at the start, faster to the end |
| `EASE_OUT` | fast at the start, slowing to the end - what a thing that stops looks like |
| `EASE_INOUT` | slow at both ends |
| `EASE_OVERSHOOT` | out, a little past the end and back |
| `EASE_BOUNCE` | out, bouncing at the end like a ball dropped on a floor |
| `EASE_STEP` | nothing until the end, then all of it |

`Ease(curve, progress)` answers a curve at a progress, and
`EaseBezier(x1, y1, x2, y2, progress)` the cubic Bezier through those two
control points - the curve a design tool gives as four numbers. Both are
signed: a curve may go past 1 and back.

## An animation

An animation is a value going from one number to another over a time:

```zig
const anim = mb.CreateAnimationTagList(&.{
    .{ .tag = motion.ANIM_From, .data = 0 },
    .{ .tag = motion.ANIM_To, .data = 100 },
    .{ .tag = motion.ANIM_Duration, .data = 400 },
    .{ .tag = motion.ANIM_Easing, .data = motion.EASE_OUT },
    .{ .tag = motion.ANIM_Signal, .data = @intCast(bit) },
    .{},
}) orelse return;
defer mb.DeleteAnimation(anim);
mb.StartAnimation(anim);
```

| Tag | |
|---|---|
| `ANIM_From`, `ANIM_To` | where the value starts and ends (0, 0); a new `ANIM_To` while it runs turns it from where it is |
| `ANIM_Duration` | milliseconds a play takes (250) |
| `ANIM_Delay` | milliseconds after the start before it moves (0) |
| `ANIM_Easing`, `ANIM_Bezier`, `ANIM_EaseHook` | its curve: an `EASE_`, four control points, or a hook of the caller's |
| `ANIM_Repeat` | how many plays (1); `ANIM_FOREVER` |
| `ANIM_PlayBack` | each play goes there and back |
| `ANIM_Rate` | steps a second, 1 to 60 (30) |
| `ANIM_StepHook`, `ANIM_DoneHook`, `ANIM_Signal` | how its owner hears of it |
| `ANIM_UserData` | handed back in every message |

Values are rounded to the nearest whole number. `StopAnimation` stops it
where it is or at its end (`STOP_WHERE_IT_IS`, `STOP_AT_END`);
`GetAnimationAttr` answers `ANIM_Value`, `ANIM_Progress` and
`ANIM_Running`. `MixColour` and `MixRect` mix two colours or two boxes by
an amount, for a step that moves more than one number.

## Hearing of it: a hook or a signal

**A signal** (`ANIM_Signal`) wakes the owner, who reads the newest value
in its own loop:

```zig
while (true) {
    const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
    if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    const value: i32 = @bitCast(@as(u32, @truncate(mb.GetAnimationAttr(anim, motion.ANIM_Value))));
    // ... use it
    if (mb.GetAnimationAttr(anim, motion.ANIM_Running) == 0) break;
}
```

Steps the program was too slow for do not pile up: one signal, the newest
value.

**A hook** (`ANIM_StepHook`) is called on the clock's task at every step
that changes the value, with an `AnimationMsg` - its `value`, its
`progress` and its `user_data`. A hook runs on someone else's task,
holding the clock, so it does little and waits for nothing: it stores the
value, or hands it to whoever draws. It may not delete its own animation;
its owner does, when the done hook or the signal tells it to.

## Timers

A timer moves nothing: it fires after a time, or every so often, and its
owner hears of it by a hook (with a `TimerMsg` and its `count`) or a
signal.

```zig
const tick = mb.CreateTimerTagList(&.{
    .{ .tag = motion.TIMER_Period, .data = 40 },  // 25 a second
    .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
    .{ .tag = motion.TIMER_Signal, .data = @intCast(bit) },
    .{},
}) orelse return;
defer mb.DeleteTimer(tick);
mb.StartTimer(tick);
```

Each period is counted from when the last firing was due, so a timer
does not drift. A firing it was too late for is not made up - a blinking
cursor that blinked three times at once after a busy moment would be
wrong - and the next is the next that has not passed. The first comes a
period after the start unless `TIMER_Delay` says otherwise.

**Pacing a program.** `C:test/Anim` draws its frames on a timer: the
hook only stores `TimerMsg.count`, the signal wakes the program for the
next frame, and a frame moves the scene on by every firing since the
last. A machine too slow for the rate draws fewer frames, and the picture
still moves at the same speed; between frames the program waits, which
leaves the time to everything else.

## Timelines

A timeline holds animations, each at an offset from its start, and plays
them as one:

```zig
const line = mb.CreateTimelineTagList(&.{
    .{ .tag = motion.TIMELINE_Signal, .data = @intCast(bit) },
    .{},
}) orelse return;
defer mb.DeleteTimeline(line);   // before the animations it holds
_ = mb.AddTimelineAnimation(line, slide, 0);
_ = mb.AddTimelineAnimation(line, fade, 150);
mb.StartTimeline(line);
```

The animations stay the caller's; the timeline gives them one time to
count from, so they keep together however late their steps come.
`TIMELINE_Reverse` plays it backwards from its end, `SetTimelineProgress`
puts every animation where it is at a moment (a scrubber), and
`StopTimeline` stops them all. An animation that plays for ever is not
taken into a timeline: it would never end.

## Moving a gadget

**A step never draws.** The clock's task must not wait for a window, and
drawing a gadget does: a step stores the gadget's new value and asks
intuition to draw it (`QueueGadgetRefresh`). Intuition's input task draws
every gadget so marked, with its newest value; one asked several times
before it gets there is drawn once, and one out of its window not at all.

```zig
fn knobStep(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const knob: *const Knob = @ptrCast(@alignCast(hook.data.?));
    _ = knob.ib.SetAttrsTagList(knob.bar, &.{
        .{ .tag = intuition.propgclass.PGA_Top, .data = @intCast(@max(msg.value, 0)) },
        .{},
    });
    knob.ib.QueueGadgetRefresh(knob.bar);
    return 0;
}
```

`SetAttrs` without a window stores; it does not draw. The animation is
deleted before the gadget it reaches.

**Turning it off.** `GA_Animate` false makes one gadget change at once
rather than move; `SA_Animate` false does it for every gadget on a
screen. A class asks before it starts anything:
`gadgetclass.animates(gadget, draw_info)`.

## What moves on its own

- **Style transitions.** A style's `STYLE_Transition` is the milliseconds
  a change into a state takes: a button fades into its pressed look, a
  field into its focused one, a line round a gadget under the pointer
  into its colour. A gadget's own style (`GA_Style`) does it for one
  gadget. See the [styles guide](styles.md).
- **fuelgauge.gadget** fills to a new level over a quarter of a second,
  slowing to the end, from wherever it is; the number counts with it.
- **spinner.gadget** is a ring of eight dots, the lit one going round
  with a fading trail behind it, while `SPINNER_Running` is on
  (`SPINNER_Period`, a turn in milliseconds, 1000). Stopped, every dot is
  lit.
- **listview.gadget and scroller.gadget** glide to a top a program sets
  (`LISTVIEW_Top`, `SCROLLER_Top`) when it is more than a line away;
  dragging, the arrows and the keys move them at once, as the hand does.
- **The busy pointer** (`WA_BusyPointer`) turns an eighth of a turn on
  each of input.device's ticks; on a screen with `SA_Animate` off it
  stands still.

## Trying it

```
C:test/Motion                    ; an animation's steps against the time
C:test/Motion CURVE 5 RATE 20    ; the bounce, twenty steps a second
C:test/Motion TIMER              ; a timer's firings against the time
C:test/Motion WINDOW             ; the curves, a gauge, a spinner, a fade
C:test/Anim RATE 50              ; a program paced by a timer
C:test/ListView                  ; choose a line, let go of the scroller
```
