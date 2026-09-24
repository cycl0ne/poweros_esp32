// SPDX-License-Identifier: MIT
//! Nodes (exec/nodes.h): what goes on an exec list.

/// ln_Type values (NT_*).
pub const NodeType = enum(u8) {
    unknown = 0,
    task = 1,
    interrupt = 2,
    device = 3,
    msgport = 4,
    message = 5,
    freemsg = 6,
    replymsg = 7,
    resource = 8,
    library = 9,
    memory = 10,
    softint = 11,
    font = 12,
    process = 13,
    semaphore = 14,
    signalsem = 15,
    bootnode = 16,
    kickmem = 17,
    graphics = 18,
    deathmessage = 19,
    /// A dos handler's ROM tag: a ResidentHandler, whose entry is the word
    /// after the tag rather than behind an InitTable.
    handler = 20,
    /// A display driver's ROM tag. It is not a library, a device or a
    /// resource - it registers itself with rtg.library and exec never puts
    /// it on a list - and saying so is worth more than calling it a
    /// library because that was the nearest thing to hand.
    ///
    /// 21 was a ROM command once. Those are gone: a command is a built-in
    /// of the shell or a program on the disk, and nothing looks for the
    /// old number.
    rtg_driver = 21,
    /// The shell's ROM tag. A ResidentHandler in shape, like a dos
    /// handler, but not one: dos gives it out as shell, BootShell and CLI,
    /// and what starts a shell is not what answers a file system packet.
    shell = 22,
    /// The board's description: a ROM tag whose rt_Init is the system tag
    /// list (sdk/libs/expansion/systemtags.zig). No start flags - there is
    /// nothing to start - and expansion.library finds it by name.
    board = 23,
    _,
};

/// struct MinNode: a node without type, priority or name (for lists of
/// hooks, and the like).
pub const MinNode = extern struct {
    succ: ?*MinNode = null,
    pred: ?*MinNode = null,
};

/// struct Node: ln_Succ, ln_Pred, ln_Type, ln_Pri, ln_Name.
pub const Node = extern struct {
    succ: ?*Node = null,
    pred: ?*Node = null,
    type: NodeType = .unknown,
    pri: i8 = 0,
    name: ?[*:0]const u8 = null,

    /// The node after this one on its list, or null when this is the last:
    /// `List.first()` and this walk the real nodes and never the tail
    /// sentinel.
    pub fn next(node: *Node) ?*Node {
        const succ = node.succ orelse return null;
        return if (succ.succ == null) null else succ;
    }
};
