# motion.library

motion.library's functions: a clock for things that move. One task runs
every animation and timer that is due, on timer.device's clock. Open it
with OpenLibrary("motion.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [AddTimelineAnimation](#addtimelineanimation) - An animation into a timeline, beginning some time after it.
- [CreateAnimationTagList](#createanimationtaglist) - An animation: a value going from one number to another over a time.
- [CreateTimelineTagList](#createtimelinetaglist) - A timeline: animations started, stopped, reversed and scrubbed as one.
- [CreateTimerTagList](#createtimertaglist) - A timer: something that fires after a time, or every so often.
- [DeleteAnimation](#deleteanimation) - An animation stopped where it is and freed.
- [DeleteTimeline](#deletetimeline) - A timeline freed; its animations stay.
- [DeleteTimer](#deletetimer) - A timer stopped and freed.
- [Ease](#ease) - Where a curve is at a point of its progress.
- [EaseBezier](#easebezier) - Where a cubic Bezier curve is at a point of its progress: a curve of the caller's own shape.
- [GetAnimationAttr](#getanimationattr) - One of an animation's attributes: where it is, or what it was told.
- [MixColour](#mixcolour) - Two colours mixed, channel by channel.
- [MixRect](#mixrect) - Two boxes mixed, edge by edge.
- [SetAnimationAttrsTagList](#setanimationattrstaglist) - An animation's tags changed, running or not.
- [SetTimelineAttrsTagList](#settimelineattrstaglist) - A timeline's tags changed.
- [SetTimelineProgress](#settimelineprogress) - Every animation of a timeline put where it is at a point of the timeline: scrubbing.
- [StartAnimation](#startanimation) - An animation run from its start.
- [StartTimeline](#starttimeline) - A timeline run from its start, or from its end reversed.
- [StartTimer](#starttimer) - A timer started from now.
- [StopAnimation](#stopanimation) - An animation stopped.
- [StopTimeline](#stoptimeline) - Every animation of a timeline stopped.
- [StopTimer](#stoptimer) - A timer stopped.

## AddTimelineAnimation

An animation into a timeline, beginning some time after it.

**SYNOPSIS**

```zig
fn AddTimelineAnimation(mb: *MotionBase, timeline: *Timeline,
    animation: *Animation, offset: u32) bool
```

**SINCE**

1.4. LVO -84.

**INPUTS**

- `timeline` - one from `CreateTimelineTagList`.
- `animation` - one from `CreateAnimationTagList`, in no timeline.
- `offset` - milliseconds from the timeline's start to this
  animation's; its own `ANIM_Delay` comes after that.

**RESULT**

True when it is in; false for one that plays for ever (a timeline has
to end) or is in a timeline already.

**BEHAVIOR**

From now on the timeline starts and stops it. Started on its own with
`StartAnimation`, it leaves the timeline.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The animation stays the caller's; deleting it takes it out of the
timeline.

**NOTES**

The timeline's length is worked out when it starts, so an animation's
duration may still be changed after it is added.

**BUGS**

None known.

**SEE ALSO**

`CreateTimelineTagList`, `StartTimeline`

**EXAMPLES**

```zig
_ = mb.AddTimelineAnimation(line, fade, 100);
```

## CreateAnimationTagList

An animation: a value going from one number to another over a time.

**SYNOPSIS**

```zig
fn CreateAnimationTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*Animation
```

**SINCE**

1.2. LVO -28.

**INPUTS**

- `tags` - what it is, or null for the defaults:
  - `ANIM_From`, `ANIM_To` (i32) - where the value starts and ends (0).
  - `ANIM_Duration` (ms) - one play (250); `ANIM_Delay` (ms) - before
    it begins (0).
  - `ANIM_Easing` (`EASE_`, `EASE_LINEAR`), or `ANIM_Bezier` (four
    16.16 control points, copied), or `ANIM_EaseHook` (a curve of the
    caller's own).
  - `ANIM_Repeat` - plays (1), `ANIM_FOREVER` for ever;
    `ANIM_PlayBack` - each play there and back.
  - `ANIM_StepHook`, `ANIM_DoneHook`, `ANIM_Signal`, `ANIM_UserData` -
    how its owner hears of it.
  - `ANIM_Rate` - steps a second, 1 to 60 (30).

**RESULT**

The animation, not running; null without the memory.

**BEHAVIOR**

It belongs to the calling task: if the task ends without deleting it,
it is stopped and freed then, and nobody is told.

A step works the value out from the time alone, so a step that comes
late - a busy system - lands where the animation should be by then, and
it ends when it should. A step that does not change the value tells
nobody.

**Its hooks** run on motion.library's task, holding the clock's
semaphore: quick, and waiting for nothing another task may hold while
it starts or stops an animation. **Its signal** goes to its owner,
which reads the newest value in its own time; steps it was too slow for
do not pile up.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs, to put it in the
  calling task's keeping.
- Interrupts: no.
- Locks: takes the clock's semaphore; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The animation is the caller's until `DeleteAnimation`. Hooks named in
the tags must stay valid for as long as it does.

**NOTES**

One clock serves every animation: steps of several animations due
together run on one wake of the clock.

**BUGS**

None known.

**SEE ALSO**

`StartAnimation`, `StopAnimation`, `DeleteAnimation`,
`SetAnimationAttrsTagList`, `GetAnimationAttr`, `Ease`

**EXAMPLES**

```zig
// A level from 20 to 80 in a third of a second, slowing to its end;
// the program hears of each step by a signal.
const bit = sys.AllocSignal(-1);
const fill = mb.CreateAnimationTagList(&[_]TagItem{
    .{ .tag = motion.ANIM_From, .data = 20 },
    .{ .tag = motion.ANIM_To, .data = 80 },
    .{ .tag = motion.ANIM_Duration, .data = 330 },
    .{ .tag = motion.ANIM_Easing, .data = motion.EASE_OUT },
    .{ .tag = motion.ANIM_Signal, .data = @intCast(bit) },
    .{},
}) orelse return;
defer mb.DeleteAnimation(fill);
mb.StartAnimation(fill);
```

## CreateTimelineTagList

A timeline: animations started, stopped, reversed and scrubbed as one.

**SYNOPSIS**

```zig
fn CreateTimelineTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*Timeline
```

**SINCE**

1.4. LVO -76.

**INPUTS**

- `tags` - or null:
  - `TIMELINE_Reverse` - it plays backwards (false).
  - `TIMELINE_DoneHook`, `TIMELINE_Signal`, `TIMELINE_UserData` - how
    its owner hears that the last of its animations has ended.

**RESULT**

The timeline, empty and not running; null without the memory.

**BEHAVIOR**

Animations go into it with `AddTimelineAnimation`, each at an offset
from its start. It runs no steps of its own: started, it gives each
animation one time to count from, so they keep together however late
their steps come. It belongs to the calling task, and goes with it.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs, to put it in the
  calling task's keeping.
- Interrupts: no.
- Locks: takes the clock's semaphore; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The timeline is the caller's until `DeleteTimeline`; the animations in
it stay the caller's too, and are deleted on their own.

**NOTES**

A box that moves and fades, a panel sliding in while its contents
follow a little after: animations of their own, one timeline.

**BUGS**

None known.

**SEE ALSO**

`AddTimelineAnimation`, `StartTimeline`, `StopTimeline`,
`SetTimelineProgress`, `DeleteTimeline`

**EXAMPLES**

```zig
const line = mb.CreateTimelineTagList(null) orelse return;
_ = mb.AddTimelineAnimation(line, slide, 0);
_ = mb.AddTimelineAnimation(line, fade, 100);
mb.StartTimeline(line);
```

## CreateTimerTagList

A timer: something that fires after a time, or every so often.

**SYNOPSIS**

```zig
fn CreateTimerTagList(mb: *MotionBase, tags: ?[*]const TagItem) ?*Timer
```

**SINCE**

1.3. LVO -60.

**INPUTS**

- `tags` - what it is, or null for the defaults:
  - `TIMER_Period` (ms) - between firings (1000).
  - `TIMER_Delay` (ms) - from `StartTimer` to the first (the period).
  - `TIMER_Repeat` - how many times it fires (1), `TIMER_FOREVER`.
  - `TIMER_Hook`, `TIMER_Signal`, `TIMER_UserData` - how its owner
    hears of a firing.

**RESULT**

The timer, not running; null without the memory.

**BEHAVIOR**

It belongs to the calling task: if the task ends without deleting it,
it is stopped and freed then.

It fires a period after each firing it was due for, so it does not
drift however late a firing comes. A firing the clock was too late for
is not made up: after a late one, the next is the next that has not
passed. **Its hook** runs on motion.library's task, holding the
clock's semaphore: quick, and waiting for nothing another task may hold
while it starts or stops a timer.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs, to put it in the
  calling task's keeping.
- Interrupts: no.
- Locks: takes the clock's semaphore; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The timer is the caller's until `DeleteTimer`. A hook named must stay
valid for as long as it does.

**NOTES**

A cursor that blinks, a key or an arrow that repeats while held, a
poll: what each would otherwise send a `timer.device` request of its
own for. Every timer and animation shares one request.

**BUGS**

None known.

**SEE ALSO**

`StartTimer`, `StopTimer`, `DeleteTimer`, `CreateAnimationTagList`

**EXAMPLES**

```zig
// A cursor that blinks twice a second, for as long as it is shown.
const blink = mb.CreateTimerTagList(&[_]TagItem{
    .{ .tag = motion.TIMER_Period, .data = 500 },
    .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
    .{ .tag = motion.TIMER_Signal, .data = @intCast(bit) },
    .{},
}) orelse return;
mb.StartTimer(blink);
```

## DeleteAnimation

An animation stopped where it is and freed.

**SYNOPSIS**

```zig
fn DeleteAnimation(mb: *MotionBase, animation: ?*Animation) void
```

**SINCE**

1.2. LVO -32.

**INPUTS**

- `animation` - one from `CreateAnimationTagList`, running or not, or
  null.

**RESULT**

Nothing.

**BEHAVIOR**

A running animation is taken off the clock first, and out of its
timeline; nobody is told. Once
this returns its step is not running and will not run again, so what
its hooks reach may go too.

**CONTEXT**

- Waits: for the clock's semaphore, while a step of any animation runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The animation's memory goes back to the system.

**NOTES**

Called from a hook of the animation itself - its done hook, say - it
is freed under the hook's feet: let the hook signal its owner instead.

**BUGS**

None known.

**SEE ALSO**

`CreateAnimationTagList`, `StopAnimation`

**EXAMPLES**

```zig
mb.DeleteAnimation(fill);
```

## DeleteTimeline

A timeline freed; its animations stay.

**SYNOPSIS**

```zig
fn DeleteTimeline(mb: *MotionBase, timeline: ?*Timeline) void
```

**SINCE**

1.4. LVO -80.

**INPUTS**

- `timeline` - one from `CreateTimelineTagList`, or null.

**RESULT**

Nothing.

**BEHAVIOR**

Its animations are stopped where they are, untold, and let go of: they
are animations on their own again, the caller's to start or delete.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The timeline's memory goes back to the system; the animations stay the
caller's.

**NOTES**

Delete the timeline before its animations, or delete them first: either
order is safe.

**BUGS**

None known.

**SEE ALSO**

`CreateTimelineTagList`, `DeleteAnimation`

**EXAMPLES**

```zig
mb.DeleteTimeline(line);
mb.DeleteAnimation(slide);
mb.DeleteAnimation(fade);
```

## DeleteTimer

A timer stopped and freed.

**SYNOPSIS**

```zig
fn DeleteTimer(mb: *MotionBase, timer: ?*Timer) void
```

**SINCE**

1.3. LVO -64.

**INPUTS**

- `timer` - one from `CreateTimerTagList`, running or not, or null.

**RESULT**

Nothing.

**BEHAVIOR**

A running timer is taken off the clock first, untold. Once this returns
its hook is not running and will not run again.

**CONTEXT**

- Waits: for the clock's semaphore, while a step of anything runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The timer's memory goes back to the system.

**NOTES**

Not from the timer's own hook: it would be freed under the hook.

**BUGS**

None known.

**SEE ALSO**

`CreateTimerTagList`, `StopTimer`

**EXAMPLES**

```zig
mb.DeleteTimer(blink);
```

## Ease

Where a curve is at a point of its progress.

**SYNOPSIS**

```zig
fn Ease(mb: *MotionBase, curve: u32, progress: u32) i32
```

**SINCE**

1.1. LVO -20.

**INPUTS**

- `curve` - an `EASE_` curve: `EASE_LINEAR`, `EASE_IN`, `EASE_OUT`,
  `EASE_INOUT`, `EASE_OVERSHOOT`, `EASE_BOUNCE`, `EASE_STEP`. One it
  does not know is linear.
- `progress` - how far along, 16.16: 0 is the start, `MOTION_ONE` the
  end. Beyond the end is the end.

**RESULT**

How far along the value is, 16.16: 0 at the start and exactly
`MOTION_ONE` at the end. Between them it may go past the end
(`EASE_OVERSHOOT`), so it is signed.

**BEHAVIOR**

- `EASE_LINEAR` - the progress itself.
- `EASE_IN`, `EASE_OUT`, `EASE_INOUT` - cubic: slow at the start, at
  the end, or at both.
- `EASE_OVERSHOOT` - out, about 10 percent past the end and back.
- `EASE_BOUNCE` - out, four bounces each lower than the last.
- `EASE_STEP` - 0 until the end, then all of it.

All in fixed point: no floating point is used.

**CONTEXT**

- Waits: no.
- Interrupts: yes; it touches nothing but its arguments.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

An animation applies its curve itself; this is for a program that
times something of its own. A value from `from` to `to` is
`from + (to - from) * Ease(...) / MOTION_ONE`, worked out in 64 bits.

**BUGS**

None known.

**SEE ALSO**

`EaseBezier`

**EXAMPLES**

```zig
// A box moved from x 10 to x 200, a third of the way through.
const progress = motion.MOTION_ONE / 3;
const eased: i64 = mb.Ease(motion.EASE_OUT, progress);
const x: i32 = @intCast(10 + @divTrunc(190 * eased, motion.MOTION_ONE));
```

## EaseBezier

Where a cubic Bezier curve is at a point of its progress: a curve of the caller's own shape.

**SYNOPSIS**

```zig
fn EaseBezier(mb: *MotionBase, x1: i32, y1: i32, x2: i32, y2: i32,
    progress: u32) i32
```

**SINCE**

1.1. LVO -24.

**INPUTS**

- `x1`, `y1`, `x2`, `y2` - the two control points, 16.16, of the curve
  from (0, 0) to (1, 1). The x's are held to 0 to `MOTION_ONE`; the y's
  may go past either end, for a curve that overshoots.
- `progress` - how far along, 16.16; beyond the end is the end.

**RESULT**

How far along the value is, 16.16: 0 at the start, exactly
`MOTION_ONE` at the end.

**BEHAVIOR**

The curve's own parameter for the progress is found by halving, with
30 bits of fraction, and the curve's height there, rounded, is the
answer. Control points (0.25, 0.1) and (0.25, 1.0) give the gentle
start and long slowing end that most interfaces use; (0, 0) and (1, 1)
are linear.

**CONTEXT**

- Waits: no.
- Interrupts: yes; it touches nothing but its arguments.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Thirty-one evaluations of the curve a call: cheap beside drawing the
step, but not free - a program calling it for thousands of points a
frame should keep a table.

**BUGS**

None known.

**SEE ALSO**

`Ease`

**EXAMPLES**

```zig
const quarter = motion.MOTION_ONE / 4;
const tenth = motion.MOTION_ONE / 10;
const eased = mb.EaseBezier(quarter, tenth, quarter, motion.MOTION_ONE, progress);
```

## GetAnimationAttr

One of an animation's attributes: where it is, or what it was told.

**SYNOPSIS**

```zig
fn GetAnimationAttr(mb: *MotionBase, animation: *Animation, attr: Tag) usize
```

**SINCE**

1.2. LVO -48.

**INPUTS**

- `animation` - one from `CreateAnimationTagList`.
- `attr` - `ANIM_Value` (i32), `ANIM_Progress` (16.16, before the
  curve), `ANIM_Running` (bool), or one of the tags it is made with.

**RESULT**

The attribute; signed ones as their bits. 0 for a tag it does not know.

**BEHAVIOR**

The value is the one its last step worked out: what a program woken by
the animation's signal draws.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

`ANIM_Bezier` answers 0: its points are copied in, not kept as the
caller's pointer.

**BUGS**

None known.

**SEE ALSO**

`SetAnimationAttrsTagList`, `CreateAnimationTagList`

**EXAMPLES**

```zig
const level: i32 = @bitCast(@as(u32, @truncate(mb.GetAnimationAttr(fill, motion.ANIM_Value))));
```

## MixColour

Two colours mixed, channel by channel.

**SYNOPSIS**

```zig
fn MixColour(mb: *MotionBase, from: u32, to: u32, amount: u32) u32
```

**SINCE**

1.2. LVO -52.

**INPUTS**

- `from`, `to` - colours, 0xAARRGGBB.
- `amount` - how far from `from` to `to`, 16.16: 0 is `from`,
  `MOTION_ONE` is `to`. Past it goes beyond `to`, as an overshooting
  curve asks.

**RESULT**

The colour, each of its four channels mixed on its own, rounded to the
nearest (a half up) and held to 0 to 255.

**BEHAVIOR**

Alpha, red, green and blue each go their own way: grey to blue fades
the red and green down while the blue comes up.

**CONTEXT**

- Waits: no.
- Interrupts: yes; it touches nothing but its arguments.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

What a step that fades a colour calls with its animation's value, run
from 0 to `MOTION_ONE`.

**BUGS**

None known.

**SEE ALSO**

`MixRect`, `CreateAnimationTagList`

**EXAMPLES**

```zig
const colour = mb.MixColour(0xFFAAAAAA, 0xFF3A6EA5, @intCast(msg.value));
```

## MixRect

Two boxes mixed, edge by edge.

**SYNOPSIS**

```zig
fn MixRect(mb: *MotionBase, from: *const Rect, to: *const Rect,
    amount: u32, result: *Rect) void
```

**SINCE**

1.2. LVO -56.

**INPUTS**

- `from`, `to` - the boxes.
- `amount` - how far from `from` to `to`, 16.16: 0 is `from`,
  `MOTION_ONE` is `to`; past it goes beyond.
- `result` - written; may be `from` or `to`.

**RESULT**

Nothing; the box in `result`.

**BEHAVIOR**

Each of the four edges goes its own way, rounded to the nearest pixel, so a box can move and grow at
once: a panel sliding in from the side, a window opening out of the
gadget that opened it.

**CONTEXT**

- Waits: no.
- Interrupts: yes; it touches nothing but its arguments.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

One animation from 0 to `MOTION_ONE` moves a whole box this way; four
animations in a timeline are for edges that move on curves of their
own.

**BUGS**

None known.

**SEE ALSO**

`MixColour`, `CreateAnimationTagList`

**EXAMPLES**

```zig
var box: graphics.Rect = undefined;
mb.MixRect(&closed, &open, @intCast(msg.value), &box);
```

## SetAnimationAttrsTagList

An animation's tags changed, running or not.

**SYNOPSIS**

```zig
fn SetAnimationAttrsTagList(mb: *MotionBase, animation: *Animation,
    tags: ?[*]const TagItem) u32
```

**SINCE**

1.2. LVO -44.

**INPUTS**

- `animation` - one from `CreateAnimationTagList`.
- `tags` - any of the tags it was made with.

**RESULT**

How many of the tags it took.

**BEHAVIOR**

**A new `ANIM_To` while it runs** turns it towards the new end from
where its value is now, over its whole duration again and with its
delay behind it: a bar told a new level twice in a row turns towards
the second without a jump. Anything else takes effect from its next
step - a new curve or duration from the point the time has reached.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Hooks named stay the caller's, and must stay valid while the
animation does.

**NOTES**

A new `ANIM_From` while it runs moves where its curve starts from, not
where the value is: the next step may jump.

**BUGS**

None known.

**SEE ALSO**

`CreateAnimationTagList`, `GetAnimationAttr`

**EXAMPLES**

```zig
_ = mb.SetAnimationAttrsTagList(fill, &[_]TagItem{
    .{ .tag = motion.ANIM_To, .data = 35 },
    .{},
});
```

## SetTimelineAttrsTagList

A timeline's tags changed.

**SYNOPSIS**

```zig
fn SetTimelineAttrsTagList(mb: *MotionBase, timeline: *Timeline,
    tags: ?[*]const TagItem) u32
```

**SINCE**

1.4. LVO -100.

**INPUTS**

- `timeline` - one from `CreateTimelineTagList`.
- `tags` - any of the tags it was made with.

**RESULT**

How many of the tags it took.

**BEHAVIOR**

They take effect from its next start: a reversed timeline set to play
forwards while it runs goes on backwards until it ends.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

A hook named stays the caller's, and must stay valid while the
timeline does.

**NOTES**

What turns a timeline round between an opening and a closing.

**BUGS**

None known.

**SEE ALSO**

`CreateTimelineTagList`, `StartTimeline`

**EXAMPLES**

```zig
_ = mb.SetTimelineAttrsTagList(line, &[_]TagItem{
    .{ .tag = motion.TIMELINE_Reverse, .data = 1 },
    .{},
});
mb.StartTimeline(line);
```

## SetTimelineProgress

Every animation of a timeline put where it is at a point of the timeline: scrubbing.

**SYNOPSIS**

```zig
fn SetTimelineProgress(mb: *MotionBase, timeline: *Timeline, at: u32) void
```

**SINCE**

1.4. LVO -96.

**INPUTS**

- `timeline` - one from `CreateTimelineTagList`.
- `at` - milliseconds from the timeline's start, forwards; past its
  end is its end.

**RESULT**

Nothing.

**BEHAVIOR**

Each animation stops and takes the value it has at that point - its
start before its offset, its end after its last play - and its step
hook and signal are told when the value moved. The timeline is left
stopped, its done hook untold; started again it runs from its start.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

What a slider dragged along a timeline calls with the slider's value:
everything moves to where it would be then, at the drag's own speed.

**BUGS**

None known.

**SEE ALSO**

`StartTimeline`, `StopTimeline`

**EXAMPLES**

```zig
mb.SetTimelineProgress(line, 150);
```

## StartAnimation

An animation run from its start.

**SYNOPSIS**

```zig
fn StartAnimation(mb: *MotionBase, animation: *Animation) void
```

**SINCE**

1.2. LVO -36.

**INPUTS**

- `animation` - one from `CreateAnimationTagList`.

**RESULT**

Nothing.

**BEHAVIOR**

The value goes back to `ANIM_From` and the animation's time starts now:
after its delay its first step runs, and its owner hears of it even
though the value has not moved yet. One that runs already starts again
from the beginning; one that ended runs again.

The first time anything is started, motion.library's task is made.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

To turn a running animation towards a new end without going back to
its start, set `ANIM_To` (`SetAnimationAttrsTagList`) instead.

**BUGS**

None known.

**SEE ALSO**

`StopAnimation`, `SetAnimationAttrsTagList`

**EXAMPLES**

```zig
mb.StartAnimation(fill);
```

## StartTimeline

A timeline run from its start, or from its end reversed.

**SYNOPSIS**

```zig
fn StartTimeline(mb: *MotionBase, timeline: *Timeline) void
```

**SINCE**

1.4. LVO -88.

**INPUTS**

- `timeline` - one from `CreateTimelineTagList`.

**RESULT**

Nothing.

**BEHAVIOR**

Its time starts now, and each animation's at its offset from that.
**Reversed** (`TIMELINE_Reverse`) every animation begins at its end
and goes back to its start, the last to begin forwards the first to
go back. When the last of its animations ends, its done hook and
signal follow theirs. One that runs already starts again.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

A panel that slid in slides out with the same timeline reversed.

**BUGS**

None known.

**SEE ALSO**

`StopTimeline`, `SetTimelineProgress`, `SetTimelineAttrsTagList`

**EXAMPLES**

```zig
mb.StartTimeline(line);
```

## StartTimer

A timer started from now.

**SYNOPSIS**

```zig
fn StartTimer(mb: *MotionBase, timer: *Timer) void
```

**SINCE**

1.3. LVO -68.

**INPUTS**

- `timer` - one from `CreateTimerTagList`.

**RESULT**

Nothing.

**BEHAVIOR**

Its first firing comes its delay from now, its count starting from 0.
One that runs already starts again from now; one that has fired all
its times runs again.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

Starting it again is how a timeout is pushed back: an inactivity timer
started anew at each key never fires while keys come.

**BUGS**

None known.

**SEE ALSO**

`StopTimer`, `CreateTimerTagList`

**EXAMPLES**

```zig
mb.StartTimer(blink);
```

## StopAnimation

An animation stopped.

**SYNOPSIS**

```zig
fn StopAnimation(mb: *MotionBase, animation: *Animation, where: u32) void
```

**SINCE**

1.2. LVO -40.

**INPUTS**

- `animation` - one from `CreateAnimationTagList`.
- `where` - `STOP_WHERE_IT_IS`, or `STOP_AT_END` to put the value at
  the end of its last play first (`ANIM_To`, or `ANIM_From` with
  play-back).

**RESULT**

Nothing.

**BEHAVIOR**

It is taken off the clock and its owner told as when it ends by
itself: with `STOP_AT_END` a last step if the value moves, then its
done hook and its signal - on the caller's task. Nothing for one that
is not running.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands; the animation can be started again.

**NOTES**

What a gadget does when it is told a value straight away: the
animation that was moving it ends where the value now is.

**BUGS**

None known.

**SEE ALSO**

`StartAnimation`, `DeleteAnimation`

**EXAMPLES**

```zig
mb.StopAnimation(fill, motion.STOP_AT_END);
```

## StopTimeline

Every animation of a timeline stopped.

**SYNOPSIS**

```zig
fn StopTimeline(mb: *MotionBase, timeline: *Timeline, where: u32) void
```

**SINCE**

1.4. LVO -92.

**INPUTS**

- `timeline` - one from `CreateTimelineTagList`.
- `where` - `STOP_WHERE_IT_IS` or `STOP_AT_END`, for each animation as
  `StopAnimation` takes it.

**RESULT**

Nothing.

**BEHAVIOR**

Each running animation is stopped and told as when it ends; the last of
them tells the timeline's done hook and signal. Nothing for a timeline
none of whose animations runs.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

`STOP_AT_END` puts each animation at its own end, forwards: for a
reversed timeline that is the end it was going away from.

**BUGS**

None known.

**SEE ALSO**

`StartTimeline`, `StopAnimation`

**EXAMPLES**

```zig
mb.StopTimeline(line, motion.STOP_AT_END);
```

## StopTimer

A timer stopped.

**SYNOPSIS**

```zig
fn StopTimer(mb: *MotionBase, timer: *Timer) void
```

**SINCE**

1.3. LVO -72.

**INPUTS**

- `timer` - one from `CreateTimerTagList`.

**RESULT**

Nothing.

**BEHAVIOR**

Taken off the clock, untold: once this returns its hook is not running
and will not run until it is started again. Nothing for one that is not
running.

**CONTEXT**

- Waits: for the clock's semaphore, while a step runs.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands; the timer can be started again.

**NOTES**

A signal it sent before it was stopped may still be waiting for the
owner: clear it with `SetSignal` before waiting on it again.

**BUGS**

None known.

**SEE ALSO**

`StartTimer`, `DeleteTimer`

**EXAMPLES**

```zig
mb.StopTimer(blink);
```
