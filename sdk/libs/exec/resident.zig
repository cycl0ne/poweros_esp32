// SPDX-License-Identifier: MIT
//! Resident modules (exec/resident.h): the ROM tag that marks a module in
//! the image, and the InitTable an auto-init library or device is made
//! from.

const NodeType = @import("nodes.zig").NodeType;
const InitFn = @import("libraries.zig").InitFn;
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const TaskFn = @import("tasks.zig").TaskFn;

/// rt_MatchWord: the ILLEGAL instruction on the 68000.
pub const RTC_MATCHWORD: u16 = 0x4AFC;

/// rt_Flags: the start classes...
pub const RTF_COLDSTART: u8 = 1 << 0;
pub const RTF_SINGLETASK: u8 = 1 << 1;
pub const RTF_AFTERDOS: u8 = 1 << 2;
/// ...a device's tag that is a `ResidentDevice`, saying what it speaks...
pub const RTF_DEVICEINFO: u8 = 1 << 3;
/// ...and: rt_Init points to an InitTable.
pub const RTF_AUTOINIT: u8 = 1 << 7;

/// rt_Init of a resident without RTF_AUTOINIT. Returns non-null on success.
pub const ResidentInitFn = *const fn (seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*anyopaque;

/// What rt_Init points to with RTF_AUTOINIT (InitTable, without
/// it_DataInit): MakeLibrary's arguments.
pub const InitTable = extern struct {
    /// it_DataSize: the base, Library included.
    data_size: u32,
    /// it_FuncTable: Open, Close, Expunge, ExtFunc, ... (for devices also
    /// BeginIO and AbortIO). A count instead of the -1 terminator.
    vectors: [*]const *const anyopaque,
    vector_count: u32,
    /// it_InitRoutine: runs on the new base, after exec has copied the
    /// tag's name, type, version and ID string into it.
    init: ?InitFn = null,
};

/// The ROM tag of a dos handler. rt_Type is
/// NT_HANDLER (.handler), rt_Flags 0 and rt_Init null, so InitCode never
/// starts it and InitResident does nothing with it; dos.library finds it by
/// name (FindResident) and runs `handler` as the handler's process.
pub const ResidentHandler = extern struct {
    resident: Resident,
    /// The handler's process entry.
    handler: TaskFn,
};

/// The ROM tag of a device that says what it speaks (rt_Flags has
/// RTF_DEVICEINFO): the command sets (`DEVIF_*`, sdk.expansion.devices)
/// a program may send it and rely on, and where its units come from. It
/// can be read without running anything - in the ROM where it is, and on
/// the disk from the file's bytes (`loadfile.findResident`) - so a
/// program finds the devices of a kind without opening or loading one.
pub const ResidentDevice = extern struct {
    resident: Resident,
    /// The command sets it speaks, DEVIF_*, ended by 0.
    speaks: [*]const u32,
    /// Its units are the board's parts of this kind (PARTKIND_*) and of
    /// the chip `unit_chip`: a unit's number its part's PART_BusUnit - the
    /// controller it is, for a UART or a bus - or else its place among the
    /// parts of its kind. 0: `units` says.
    unit_part: u32 = 0,
    /// With no part kind: units 0 to units - 1; 0 for a device whose units
    /// come and go (a connection each) and are listed by none.
    units: u32 = 1,
    /// A label for each of those, or null for none.
    unit_labels: ?[*]const [*:0]const u8 = null,
    /// With a part kind, the chip its parts must be (CHIP_*), so devices
    /// for different chips of one kind - a network device for each MAC -
    /// each find their own; 0xFFFF_FFFF (CHIP_ANY): any.
    unit_chip: u32 = 0xFFFF_FFFF,
};

/// The revision an ID string gives - "acm.device 1.2 (12.10.2026)": the
/// number after the point of the first version in it; 0 when it gives
/// none.
pub fn revisionOf(id_string: []const u8) u16 {
    var at: usize = 0;
    while (at + 3 < id_string.len) : (at += 1) {
        if (id_string[at] != ' ' or !isDigit(id_string[at + 1])) continue;
        var point = at + 1;
        while (point < id_string.len and isDigit(id_string[point])) point += 1;
        if (point + 1 >= id_string.len or id_string[point] != '.' or !isDigit(id_string[point + 1])) continue;
        var revision: u16 = 0;
        var digit = point + 1;
        while (digit < id_string.len and isDigit(id_string[digit]) and revision < 6553) : (digit += 1) {
            revision = revision * 10 + (id_string[digit] - '0');
        }
        return revision;
    }
    return 0;
}

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

/// struct Resident (a ROM tag).
pub const Resident = extern struct {
    /// rt_MatchWord: RTC_MATCHWORD.
    match_word: u16 = RTC_MATCHWORD,
    /// rt_MatchTag: this tag itself. A match word alone could be anything.
    match_tag: *const Resident,
    /// rt_EndSkip: where the scan goes on (the module's end); null: right
    /// after the tag.
    end_skip: ?*const anyopaque = null,
    /// rt_Flags: RTF_COLDSTART, RTF_SINGLETASK, RTF_AFTERDOS, RTF_AUTOINIT.
    flags: u8 = 0,
    /// rt_Version
    version: u8 = 0,
    /// rt_Type: NT_LIBRARY, NT_DEVICE, ...
    type: NodeType = .unknown,
    /// rt_Pri: the order InitCode starts residents in, highest first.
    pri: i8 = 0,
    /// rt_Name
    name: [*:0]const u8,
    /// rt_IdString
    id_string: ?[*:0]const u8 = null,
    /// rt_Init: a ResidentInitFn, or with RTF_AUTOINIT an *const InitTable.
    init: ?*const anyopaque = null,
};
