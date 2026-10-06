# Motion

Things that move - a gauge filling, a list gliding to a new line, a
button fading into its pressed look, a ring of dots going round - all run
on one clock: `motion.library`, in the ROM. So do things that only have
to happen later, or every so often: a cursor that blinks, a key that
repeats, a poll. This guide is how that clock works, what a program puts
on it - animations, timers, timelines - how it hears of them, and how a
gadget moves without drawing on someone else's task.

`C:test/Motion WINDOW` shows most of it at once: seven curves side by
side on one timeline, a gauge, a spinner and a button that fades.

## Opening it

```zig
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const motion = sdk.motion;
const TagItem = sdk.utility.TagItem;
const MotionBase = sdk.interface.motion.MotionBase;

const lib = sys.OpenLibrary(motion.MOTIONNAME, 1) orelse return dos.RETURN_FAIL;
defer sys.CloseLibrary(lib);
const mb: *MotionBase = @ptrCast(lib);
```

The ROM's motion.library, 1.4, has every call in this guide. The
structures and tags are in `sdk.motion`, the calls in
`sdk.interface.motion`.

## The clock

One task runs everything that is due: every animation and every timer of
every program. It is made the first time something is started, at
priority 10 - above programs, below input.device and intuition's input
task, so a late step stutters rather than the pointer. The clock is
`timer.device`'s, and the task keeps one request out only while
something is due; while nothing moves it sleeps and costs nothing. Steps
of several animations due together run on one wake.

**A step is worked out from the time, not counted.** An animation's value
is where it should be at the moment the step runs: a step that comes late
- a busy system - lands further along, and the animation still ends when
it should. A step that would not change the value tells nobody - but
the first one after a start always tells.

**Everything on the clock belongs to the task that made it.** A task that
ends without deleting what it made has it stopped and freed as it ends,
and nobody is told - so no hook is ever called into a program that has
gone. A program still deletes what it makes, and it may do so in any
order.

## Numbers

Progress and curves are 16.16 fixed point: `MOTION_ONE` (65536) is 1.0.
No call uses floating point.

Values are signed 32-bit numbers, rounded to the nearest whole one. A
tag's data is a `usize`, so a negative value goes in by its bits, and a
value read back with `GetAnimationAttr` comes out the same way:

```zig
.{ .tag = motion.ANIM_From, .data = @bitCast(@as(isize, -40)) },

const value: i32 = @bitCast(@as(u32, @truncate(mb.GetAnimationAttr(anim, motion.ANIM_Value))));
```

## Curves

How a value goes from its start to its end is a curve on the progress
from 0 to 1. Every curve starts at exactly 0 and ends at exactly
`MOTION_ONE`; between them it may go past the end and back, so a curve's
answer is signed.

| Curve | |
|---|---|
| `EASE_LINEAR` | the same speed all the way (the default) |
| `EASE_IN` | slow at the start, faster to the end (cubic) |
| `EASE_OUT` | fast at the start, slowing to the end - what a thing that stops looks like (cubic) |
| `EASE_INOUT` | slow at both ends, fastest in the middle (cubic) |
| `EASE_OVERSHOOT` | out, about a tenth past the end and back |
| `EASE_BOUNCE` | out, the drop and then three bounces each lower than the last, like a ball dropped on a floor |
| `EASE_STEP` | nothing until the end, then all of it |

An animation applies its curve itself. A program that times something of
its own asks for a curve's value directly:

```zig
// A box moved from x 10 to x 200, a third of the way through.
const progress = motion.MOTION_ONE / 3;
const eased: i64 = mb.Ease(motion.EASE_OUT, progress);
const x: i32 = @intCast(10 + @divTrunc(190 * eased, motion.MOTION_ONE));
```

`EaseBezier(x1, y1, x2, y2, progress)` is the cubic Bezier from (0, 0)
to (1, 1) through two control points - the curve a design tool gives as
four numbers. The x's are held to 0 to 1; the y's may go past either
end, for a curve that overshoots. (0.25, 0.1) and (0.25, 1.0) give the
gentle start and long slowing end most interfaces use:

```zig
const quarter = motion.MOTION_ONE / 4;
const tenth = motion.MOTION_ONE / 10;
const eased = mb.EaseBezier(quarter, tenth, quarter, motion.MOTION_ONE, progress);
```

It finds the curve's point by halving - thirty-two evaluations a call:
cheap beside drawing a step, but a program that wants thousands of points
a frame keeps a table.

### A curve on an animation

An animation takes one of three: an `EASE_` (`ANIM_Easing`), two
control points as four numbers (`ANIM_Bezier`, a pointer to `[4]i32`,
copied), or a hook
of the program's own (`ANIM_EaseHook`). The last one set wins.

```zig
const points = [4]i32{ quarter, tenth, quarter, motion.MOTION_ONE };
.{ .tag = motion.ANIM_Bezier, .data = @intFromPtr(&points) },
```

An ease hook is called with an `AnimationMsg` of kind `ANIMMSG_EASE`;
its `progress` is the plain progress, and the hook answers the eased one,
16.16, as the bits of an `i32`:

```zig
/// Three steps of equal height: a value that clicks rather than glides.
fn threeSteps(_: *sdk.utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const third = motion.MOTION_ONE / 3;
    // Typed first: @min answers the narrowest type that holds 3.
    const step: u32 = @min(msg.progress / third, 3);
    return @min(step * third + step / 3, motion.MOTION_ONE);
}

var ease_hook: sdk.utility.Hook = .{ .entry = &threeSteps };
// ... .{ .tag = motion.ANIM_EaseHook, .data = @intFromPtr(&ease_hook) },
```

It runs where the step that asks for it runs: on the clock's task, or
on a caller's for a stop or a timeline set to a point (see below).

## Animations

An animation is a value going from one number to another over a time:

```zig
const bit = sys.AllocSignal(-1);
if (bit < 0) return dos.RETURN_FAIL;
defer sys.FreeSignal(bit);

const fill = mb.CreateAnimationTagList(&[_]TagItem{
    .{ .tag = motion.ANIM_From, .data = 20 },
    .{ .tag = motion.ANIM_To, .data = 80 },
    .{ .tag = motion.ANIM_Duration, .data = 330 },
    .{ .tag = motion.ANIM_Easing, .data = motion.EASE_OUT },
    .{ .tag = motion.ANIM_Signal, .data = @intCast(bit) },
    .{},
}) orelse return dos.RETURN_FAIL;
defer mb.DeleteAnimation(fill);
mb.StartAnimation(fill);
```

| Tag | |
|---|---|
| `ANIM_From`, `ANIM_To` | `i32`: where the value starts and ends (0, 0) |
| `ANIM_Duration` | milliseconds one play takes (250) |
| `ANIM_Delay` | milliseconds after the start before it moves (0) |
| `ANIM_Easing`, `ANIM_Bezier`, `ANIM_EaseHook` | its curve (`EASE_LINEAR`) |
| `ANIM_Repeat` | how many plays (1); `ANIM_FOREVER` |
| `ANIM_PlayBack` | each play goes there and back (false) |
| `ANIM_Rate` | steps a second, 1 to 60 (30) |
| `ANIM_StepHook` | a hook called at each step that changes the value |
| `ANIM_DoneHook` | a hook called once, when it ends or is stopped |
| `ANIM_Signal` | a signal number sent at each step that changes the value, and at the end (none) |
| `ANIM_UserData` | the program's, handed back in every `AnimationMsg` |

`CreateAnimationTagList` makes it, not running; null is no memory.

- **`StartAnimation`** runs it from its start: the value goes back to
  `ANIM_From`, and after its delay the first step runs. One that runs
  already starts again from the beginning; one that ended runs again.
- **`StopAnimation(anim, where)`** stops it, its value left where it is
  (`STOP_WHERE_IT_IS`) or put at the end of its last play
  (`STOP_AT_END`: `ANIM_To`, or `ANIM_From` with play-back). Its owner is
  told as when it ends by itself - a last step if the value moves, then
  its done hook and signal - on the caller's task. It can be started
  again.
- **`DeleteAnimation`** takes it off the clock, untold, and frees it.
  Once it returns, its hooks are not running and never will again, so
  what they reach may go too. Null is allowed.
- **`GetAnimationAttr(anim, attr)`** answers `ANIM_Value` (the value its
  last step worked out), `ANIM_Progress` (16.16, before the curve),
  `ANIM_Running`, or any tag it was made with - except `ANIM_Bezier`,
  whose points were copied, which answers 0.
- **`SetAnimationAttrsTagList(anim, tags)`** changes any of its tags,
  running or not, and answers how many it took.

### Turning a running animation

**A new `ANIM_To` while it runs** turns it towards the new end from where
its value is now, over its whole duration again: a bar told a new level
twice in a row turns towards the second without a jump. `StartAnimation`
would send it back to `ANIM_From` first.

```zig
// The level changed again before the bar got there.
_ = mb.SetAnimationAttrsTagList(fill, &[_]TagItem{
    .{ .tag = motion.ANIM_To, .data = 35 },
    .{},
});
```

Anything else takes effect from its next step - a new curve or duration
from the point the time has reached. A new `ANIM_From` while it runs
moves where its curve starts from, not where the value is, so the next
step may jump.

## Hearing of it: a signal or a hook

Each animation, timer and timeline says how its owner hears of it, and
may use both.

### A signal

The owner is woken and reads the newest value in its own loop, on its
own task. Steps it was too slow for do not pile up: one signal, the
newest value.

```zig
const mask = @as(u32, 1) << @intCast(bit);
while (true) {
    const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
    if (got & exec.SIGBREAKF_CTRL_C != 0) {
        mb.StopAnimation(fill, motion.STOP_WHERE_IT_IS);
        break;
    }
    const value: i32 = @bitCast(@as(u32, @truncate(mb.GetAnimationAttr(fill, motion.ANIM_Value))));
    draw(value);
    if (mb.GetAnimationAttr(fill, motion.ANIM_Running) == 0) break; // that was the end
}
```

This is the way for a program: it draws on its own task, at its own
pace, and may wait for whatever it likes.

### A hook

A step hook is called at each step that changes the value, a done hook
once at the end, each with the animation as the object and an
`AnimationMsg` as the message:

| `AnimationMsg` | |
|---|---|
| `kind` | `ANIMMSG_STEP`, `ANIMMSG_DONE` (or `ANIMMSG_EASE` for an ease hook) |
| `value` | the new value; for done, the last |
| `progress` | how far through its play, 16.16, before the curve |
| `user_data` | `ANIM_UserData` |

**A hook runs holding the clock** - on the clock's task, or on the task that
called `StopAnimation`, `StopTimeline` or `SetTimelineProgress`, which run
the hooks they cause themselves. So it is quick, it waits for nothing, and
it never waits for something another task may hold while that task starts or
stops an animation - which rules out drawing into a window, and any
semaphore a program's own loop takes. A spinlock is safe, since no call here
is made while one is held, and it is what a value of more than one word
needs: on two cores the hook really runs beside the loop that reads it,
which could otherwise read half of it. It stores the value, or hands it on.
It may not delete its own animation: it would be freed under the hook. It
signals its owner instead, and the owner deletes it.

```zig
const Gauge = struct {
    level: i32 = 0,
};

fn gaugeStep(hook: *sdk.utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const gauge: *Gauge = @ptrCast(@alignCast(hook.data.?));
    gauge.level = msg.value; // stored, not drawn
    return 0;
}

var gauge: Gauge = .{};
var step_hook: sdk.utility.Hook = .{ .entry = &gaugeStep, .data = &gauge };
// ... .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&step_hook) },
```

A hook named in a tag must stay valid for as long as the animation does:
keep it beside the animation, and delete the animation first.

## Mixing colours and boxes

A step that moves more than one number runs an animation from 0 to
`MOTION_ONE` and mixes by its value:

```zig
// A colour fading from grey to blue, each channel on its own.
const colour = mb.MixColour(0xFFAAAAAA, 0xFF3A6EA5, @intCast(msg.value));

// A box moving and growing at once: a panel sliding in, a window opening
// out of the gadget that opened it.
var box: graphics.Rect = undefined;
mb.MixRect(&closed, &opened, @intCast(msg.value), &box);
```

`MixColour` mixes alpha, red, green and blue each its own way (0xAARRGGBB),
rounded and held to 0 to 255; `MixRect` mixes the four edges, rounded to
the pixel, and `result` may be `from` or `to`. An amount past
`MOTION_ONE` goes beyond `to`, as an overshooting curve asks. Both
touch nothing but their arguments, so they may be called anywhere - in a
hook, in an interrupt. Four animations in a timeline are for edges that
move on curves of their own.

## Timers

A timer moves nothing: it fires after a time, or every so often.

```zig
// A cursor that blinks twice a second, for as long as it is shown.
const blink = mb.CreateTimerTagList(&[_]TagItem{
    .{ .tag = motion.TIMER_Period, .data = 500 },
    .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
    .{ .tag = motion.TIMER_Signal, .data = @intCast(bit) },
    .{},
}) orelse return dos.RETURN_FAIL;
defer mb.DeleteTimer(blink);
mb.StartTimer(blink);
```

| Tag | |
|---|---|
| `TIMER_Period` | milliseconds between firings (1000) |
| `TIMER_Delay` | milliseconds from `StartTimer` to the first firing (the period) |
| `TIMER_Repeat` | how many times it fires (1); `TIMER_FOREVER` |
| `TIMER_Hook` | a hook called at each firing, with a `TimerMsg` |
| `TIMER_Signal` | a signal number sent at each firing (none) |
| `TIMER_UserData` | the program's, handed back in every `TimerMsg` |

A `TimerMsg` holds `count` (how many times it has fired, this one
counted), `last` (whether this is the last) and `user_data`.

Each period is counted from when the last firing was due, so a timer does
not drift. A firing it was too late for is not made up - a cursor that
blinked three times at once after a busy moment would be wrong - and the
next is the next that has not passed.

- **`StartTimer`** starts it from now: its first firing comes its delay
  from now, its count from 0. One that runs starts again from now; one
  that has fired all its times runs again.
- **`StopTimer`** takes it off the clock, untold: once it returns, its
  hook is not running and will not run until it is started again.
- **`DeleteTimer`** stops it and frees it. Null is allowed; not from its
  own hook.

### A timeout pushed back

Starting a timer that runs again is how a timeout is pushed back. A
screen that dims after half a minute without a key:

```zig
const idle = mb.CreateTimerTagList(&[_]TagItem{
    .{ .tag = motion.TIMER_Period, .data = 30_000 },
    .{ .tag = motion.TIMER_Signal, .data = @intCast(idle_bit) },
    .{},
}) orelse return dos.RETURN_FAIL;
defer mb.DeleteTimer(idle);
mb.StartTimer(idle);

// At every key: from now again, so it never fires while keys come.
mb.StartTimer(idle);

// Woken by idle_mask: dim, and wait for a key to start it again.
```

### A key that repeats

A delay before the first firing, then a shorter period - and
`StopTimer` when the key comes up:

```zig
const repeat = mb.CreateTimerTagList(&[_]TagItem{
    .{ .tag = motion.TIMER_Delay, .data = 400 },
    .{ .tag = motion.TIMER_Period, .data = 60 },
    .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
    .{ .tag = motion.TIMER_Signal, .data = @intCast(repeat_bit) },
    .{},
}) orelse return dos.RETURN_FAIL;
defer mb.DeleteTimer(repeat);

// Key down: act once now, then on every firing.
mb.StartTimer(repeat);
// Key up:
mb.StopTimer(repeat);
```

### Pacing a program

`C:test/Anim` draws its frames on a timer: the hook only stores
`TimerMsg.count`, the signal wakes the program for the next frame, and a
frame moves the scene on by every firing since the last. A machine too
slow for the rate draws fewer frames and the picture still moves at the
same speed; between frames the program waits, which leaves the time to
everything else.

## Timelines

A timeline holds animations, each at an offset from its start, and plays
them as one: started, stopped, reversed and scrubbed together.

```zig
const line = mb.CreateTimelineTagList(&[_]TagItem{
    .{ .tag = motion.TIMELINE_Signal, .data = @intCast(ended_bit) },
    .{},
}) orelse return dos.RETURN_FAIL;
defer mb.DeleteTimeline(line);

if (!mb.AddTimelineAnimation(line, slide, 0)) return dos.RETURN_FAIL;
if (!mb.AddTimelineAnimation(line, fade, 150)) return dos.RETURN_FAIL;
mb.StartTimeline(line);
```

| Tag | |
|---|---|
| `TIMELINE_Reverse` | it plays backwards, from its end to its start (false) |
| `TIMELINE_DoneHook` | a hook called when the last of its animations ends, with an `AnimationMsg` of kind `ANIMMSG_DONE` and the timeline as the object |
| `TIMELINE_Signal` | a signal number sent when it ends (none) |
| `TIMELINE_UserData` | the program's, handed back in its `AnimationMsg` |

The timeline runs no steps of its own: it gives each animation one time
to count from, so they keep together however late their steps come.
The animations stay the program's and keep their own hooks and signals.

- **`AddTimelineAnimation(line, anim, offset)`** puts an animation in,
  beginning `offset` milliseconds after the timeline; its own
  `ANIM_Delay` comes after that. It answers false for one that plays for
  ever (a timeline has to end) or is in a timeline already. The length is
  worked out at each start, so an animation's duration may still change.
  An animation started on its own with `StartAnimation` leaves its
  timeline; deleting it takes it out.
- **`StartTimeline`** starts its time now, each animation at its offset.
  Reversed, every animation begins at its end and goes back to its start,
  the last to begin forwards the first to go back. When the last of them
  ends, the timeline's done hook and signal follow theirs.
- **`StopTimeline(line, where)`** stops every running animation as
  `StopAnimation` does, each told, and then the timeline. `STOP_AT_END`
  is each animation's own end, forwards - for a reversed timeline, the
  end it was going away from.
- **`SetTimelineProgress(line, at)`** puts every animation where it is
  `at` milliseconds from the start - its start before its offset, its end
  after its last play - and tells their step hooks and signals where a
  value moved. The timeline is left stopped, untold.
- **`SetTimelineAttrsTagList(line, tags)`** changes its tags, from its
  next start: a reversed timeline set to play forwards while it runs goes
  on backwards until it ends.
- **`DeleteTimeline`** stops its animations where they are, untold, lets
  go of them - they are animations on their own again - and frees the
  timeline. Timeline first or animations first: either order is safe.

### There and back

A panel that slid in slides out with the same timeline reversed:

```zig
fn slidePanel(mb: *MotionBase, line: *motion.Timeline, out: bool) void {
    _ = mb.SetTimelineAttrsTagList(line, &[_]TagItem{
        .{ .tag = motion.TIMELINE_Reverse, .data = @intFromBool(out) },
        .{},
    });
    mb.StartTimeline(line);
}
```

`C:test/Motion WINDOW` does this at every end: woken by the timeline's
signal, it turns it round and starts it again.

### Scrubbing

A slider dragged along a timeline puts everything where it would be at
that moment, at the drag's own speed:

```zig
// The slider runs from 0 to the timeline's length in milliseconds.
mb.SetTimelineProgress(line, @intCast(slider_top));
```

Started again afterwards, the timeline runs from its start.

## Moving a gadget

**A step never draws.** The clock's task must not wait for a window, and
drawing a gadget does: a step stores the gadget's new value and asks
intuition to draw it (`QueueGadgetRefresh`). Intuition's input task draws
every gadget so marked with its newest value; one asked several times
before it gets there is drawn once, and one out of its window not at all.

```zig
const Knob = struct {
    ib: *IntuitionBase,
    bar: *intuition.Object,
};

fn knobStep(hook: *sdk.utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const knob: *const Knob = @ptrCast(@alignCast(hook.data.?));
    _ = knob.ib.SetAttrsTagList(knob.bar, &[_]TagItem{
        .{ .tag = intuition.propgclass.PGA_Top, .data = @intCast(@max(msg.value, 0)) },
        .{},
    });
    knob.ib.QueueGadgetRefresh(knob.bar);
    return 0;
}
```

`SetAttrs` without a window stores; it does not draw. The animation is
deleted before the gadget it reaches.

**In a class of one's own**, `sdk.gadgets.moving.Moving` does all of
this: kept in the instance data, `towards(base, o, gi, value, time)`
takes the value it shows (`shown`) to a new one, slowing to the end and
from wherever it is, and queues the gadget at each step; `jump` puts it
there at once, and `dispose` deletes the animation before the gadget
goes. `towards` answers false when the value is there at once - out of a
window, on a screen that does not move, without motion.library - and the
class draws it itself:

```zig
own.level = new_level;
if (!own.needle.towards(base, o, gi, own.level, 250)) redraw(base, o, gi);
```

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
- **meter.gadget** swings its needle, **arc.gadget** fills its ring and
  **roller.gadget** turns its wheel to a value a program sets, over a
  moment; arc and roller, turned by the pointer, follow it at once.
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

## A whole program

A number counted from 0 to 100 over a second, bouncing at the end, each
step printed as it is heard; Ctrl-C stops it where it is.

```zig
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const motion = sdk.motion;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const MotionBase = sdk.interface.motion.MotionBase;
const Printf = dos.stdio.Printf;

const VERSION_STRING = "\x00$VER: Bounce 1.0 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    const motion_lib = sys.OpenLibrary(motion.MOTIONNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{motion.MOTIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(motion_lib);
    const mb: *MotionBase = @ptrCast(motion_lib);

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const mask = @as(u32, 1) << @intCast(bit);

    const count = mb.CreateAnimationTagList(&[_]TagItem{
        .{ .tag = motion.ANIM_To, .data = 100 },
        .{ .tag = motion.ANIM_Duration, .data = 1000 },
        .{ .tag = motion.ANIM_Easing, .data = motion.EASE_BOUNCE },
        .{ .tag = motion.ANIM_Rate, .data = 20 },
        .{ .tag = motion.ANIM_Signal, .data = @intCast(bit) },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer mb.DeleteAnimation(count);
    mb.StartAnimation(count);

    while (true) {
        const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
        const value: i32 = @bitCast(@as(u32, @truncate(mb.GetAnimationAttr(count, motion.ANIM_Value))));
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            mb.StopAnimation(count, motion.STOP_WHERE_IT_IS);
            _ = Printf(dl, "Stopped at %d\n", .{value});
            return dos.RETURN_WARN;
        }
        _ = Printf(dl, "%3d\n", .{value});
        if (mb.GetAnimationAttr(count, motion.ANIM_Running) == 0) return dos.RETURN_OK;
    }
}
```

The program owns its signal, its animation and both libraries, and gives
them back in the opposite order through its `defer`s: the animation goes
before motion.library is closed.

## In short

| Call | Waits | |
|---|---|---|
| `Ease`, `EaseBezier`, `MixColour`, `MixRect` | no | touch nothing but their arguments: anywhere, an interrupt included |
| every other call | for the clock's semaphore, while a step runs | never with a spinlock held |

Every call is for a task; a process is not needed. A hook runs holding
the clock: it stores and signals, and never deletes what it belongs to -
`DeleteAnimation` and `DeleteTimer` from an animation's or a timer's own
hook would free it under the hook.

## Trying it

```
C:test/Motion                    ; an animation's steps against the time
C:test/Motion CURVE 5 RATE 20    ; the bounce, twenty steps a second
C:test/Motion TIMER              ; a timer's firings against the time
C:test/Motion WINDOW             ; the curves, a gauge, a spinner, a fade
C:test/Anim RATE 50              ; a program paced by a timer
C:test/ListView                  ; choose a line, let go of the scroller
```

## See also

- `sdk/docs/autodocs/motion.md` - every call, in full.
- `sdk/libs/motion/motion.zig` - the tags, the messages, the curves.
- `sdk/libs/gadgets/moving.zig` - a gadget's value moving to a new one.
- The [styles guide](styles.md) - `STYLE_Transition`.
