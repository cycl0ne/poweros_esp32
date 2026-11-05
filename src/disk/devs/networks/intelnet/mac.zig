// SPDX-License-Identifier: MIT
//! The controller's registers, for intelnet.device: what the parts have
//! in common, which is everything but where the interrupt cause block
//! sits (`family/_family.zig`).
//!
//! Every call here is register reads and writes at `at`, the address the
//! function's first base address register was placed at. The controller
//! keeps all its state itself, so nothing is held here.
//!
//! **The PHY** is a part of its own, reached a register at a time
//! through MDIC: an address, a register number, an operation, and a
//! ready bit the controller sets when the transfer over the two-wire
//! management bus is done. The internal PHY of every part here answers
//! at address 1.
//!
//! **The receive filter** is three things at once. The exact address
//! registers (RAL and RAH) take frames for the station address. The
//! multicast table takes a group by a hash of its address: twelve bits
//! taken from the last two bytes, one of 4096 bits in 128 registers, so
//! a group that was never joined can get through and the unit above
//! drops it. And the receive control register has the two blunt
//! instruments - every multicast frame, and every frame at all.

const barrier = @import("sdk").hardware.barrier;
const reg = @import("sdk").hardware.mmio.reg;
const Family = @import("family/_family.zig").Family;

// --- the registers ----------------------------------------------------------------

const ctrl = 0x00000;
const status = 0x00008;
const ctrl_ext = 0x00018;
const mdic = 0x00020;
const rctl = 0x00100;
const tctl = 0x00400;
const gpie = 0x01514;
const eims = 0x01524;
const eimc = 0x01528;
const eiac = 0x0152C;
const eicr = 0x01580;
const eitr0 = 0x01680;
const ivar0 = 0x01700;
const ivar_misc = 0x01740;
const rxcsum = 0x05000;
/// RXCSUM: the IP header's checksum is checked, and the transport
/// part's. The bit that would turn the descriptor's checksum field into
/// a hash of the addresses is left clear: neither is read.
const rxcsum_ip: u32 = 0x0000_0100;
const rxcsum_transport: u32 = 0x0000_0200;
const mta = 0x05200;
const ral0 = 0x05400;
const rah0 = 0x05404;

/// The multicast table's registers, 32 bits of the hash each.
const mta_words = 128;

/// MDIC: the PHY's register, the PHY itself, the operation to do, and
/// what the controller answers with - done, or it could not.
const mdic_reg_shift = 16;
const mdic_phy_shift = 21;
const mdic_write: u32 = 0x0400_0000;
const mdic_ready: u32 = 0x1000_0000;
const mdic_error: u32 = 0x4000_0000;

/// Where the internal PHY answers.
const phy_address: u32 = 1;

/// How long one transfer over the management bus is waited for, in
/// register reads. One takes tens of microseconds.
const mdio_tries = 20_000;

/// CTRL: the link set up, and the whole function reset.
const ctrl_slu: u32 = 0x0000_0040;
const ctrl_rst: u32 = 0x0400_0000;

/// CTRL_EXT: a driver has the function, which is what the firmware's own
/// management reads to leave it alone.
const ctrl_ext_drv_load: u32 = 0x1000_0000;

/// RCTL: receiving on, every frame taken, every multicast frame taken,
/// broadcast frames taken, and the checksum stripped off what comes in.
const rctl_en: u32 = 0x0000_0002;
const rctl_upe: u32 = 0x0000_0008;
const rctl_mpe: u32 = 0x0000_0010;
const rctl_bam: u32 = 0x0000_8000;
const rctl_secrc: u32 = 0x0400_0000;

/// TCTL: sending on, and short frames padded to the minimum.
const tctl_en: u32 = 0x0000_0002;
const tctl_psp: u32 = 0x0000_0008;

/// RAH: this address register holds an address.
const rah_av: u32 = 0x8000_0000;

/// GPIE: a cause cleared as its interrupt is taken rather than on the
/// next one, the extended registers in charge of the vectors, a mask bit
/// cleared with its cause, and the vector table's pending bits kept.
const gpie_nsicr: u32 = 0x0000_0001;
const gpie_msix: u32 = 0x0000_0010;
const gpie_eiame: u32 = 0x4000_0000;
const gpie_pba: u32 = 0x8000_0000;

/// An entry in the interrupt vector allocation registers names a vector
/// and has this bit set.
const ivar_valid: u32 = 0x80;

/// The extended cause the mapped "other" causes - a link that came or
/// went among them - are raised on.
pub const eicr_other: u32 = 0x8000_0000;

/// The causes in the first block: a link that changed, a frame received,
/// a frame sent, and a frame lost for want of a descriptor.
pub const cause_lsc: u32 = 0x0000_0004;
pub const cause_rxdmt0: u32 = 0x0000_0010;
pub const cause_rxo: u32 = 0x0000_0040;
pub const cause_rxdw: u32 = 0x0000_0080;
pub const cause_txdw: u32 = 0x0000_0001;

// --- reading and writing ----------------------------------------------------------

pub fn read(at: usize, offset: usize) u32 {
    return reg(at + offset).*;
}

pub fn write(at: usize, offset: usize, value: u32) void {
    reg(at + offset).* = value;
}

/// Whether a function answers at `at`: a status register of all ones is
/// a function that is not there, or one whose memory was never placed.
pub fn present(at: usize) bool {
    return read(at, status) != 0xFFFF_FFFF;
}

pub fn statusWord(at: usize) u32 {
    return read(at, status);
}

// --- starting from nothing --------------------------------------------------------

/// Every interrupt masked and every cause taken, so nothing is raised
/// while the rings are being set up or taken down.
pub fn silence(at: usize, family: *const Family) void {
    write(at, family.imc, 0xFFFF_FFFF);
    write(at, eimc, 0xFFFF_FFFF);
    _ = read(at, family.icr);
    _ = read(at, eicr);
}

/// The function reset, and whether it came back: the reset bit is set
/// and read until the controller clears it, which it does once its own
/// state machines have run. Everything the driver had written is gone
/// afterwards, the station address included - the controller loads that
/// from its own storage again.
pub fn reset(at: usize, family: *const Family) bool {
    silence(at, family);
    write(at, rctl, 0);
    write(at, tctl, tctl_psp);
    barrier.full();
    write(at, ctrl, read(at, ctrl) | ctrl_rst);
    // Each read is a transaction on the bus, so this is milliseconds on
    // a machine and less on an emulator; the controller asks for about
    // one millisecond.
    var tries: u32 = 0;
    while (tries < 200_000) : (tries += 1) {
        const control = read(at, ctrl);
        if (control == 0xFFFF_FFFF) return false;
        if (control & ctrl_rst == 0) {
            silence(at, family);
            write(at, ctrl_ext, read(at, ctrl_ext) | ctrl_ext_drv_load);
            return true;
        }
    }
    return false;
}

/// The link brought up: the controller drives its own medium from here,
/// and reports what came of it in its status register (`link.zig`).
pub fn startLink(at: usize) void {
    write(at, ctrl, read(at, ctrl) | ctrl_slu);
}

// --- the station address and the groups -------------------------------------------

/// The address the controller came with, which it loaded into its first
/// exact address register.
pub fn stationAddress(at: usize) [6]u8 {
    const low = read(at, ral0);
    const high = read(at, rah0);
    return .{
        @truncate(low),       @truncate(low >> 8),
        @truncate(low >> 16), @truncate(low >> 24),
        @truncate(high),      @truncate(high >> 8),
    };
}

/// The address the controller takes frames for. The valid bit goes on
/// last: the two halves are one entry, and an entry half written would
/// match an address that is nobody's.
pub fn setStation(at: usize, address: *const [6]u8) void {
    write(at, rah0, 0);
    write(at, ral0, @as(u32, address[0]) | @as(u32, address[1]) << 8 |
        @as(u32, address[2]) << 16 | @as(u32, address[3]) << 24);
    write(at, rah0, @as(u32, address[4]) | @as(u32, address[5]) << 8 | rah_av);
}

/// Which of the 4096 hash bits a group address falls on, as the
/// controller works it out with the multicast offset left at 0: twelve
/// bits of its last two bytes, from the fifth.
pub fn groupHash(address: *const [6]u8) u32 {
    return (@as(u32, address[5]) << 8 | address[4]) >> 4 & 0xFFF;
}

/// The multicast table written from `hash`, a bit per group that was
/// joined.
pub fn setGroups(at: usize, hash: *const [mta_words]u32) void {
    for (hash, 0..) |word, index| write(at, mta + 4 * index, word);
}

/// How many words the multicast table takes.
pub const groups_words = mta_words;

// --- receiving and sending --------------------------------------------------------

/// Receiving on, with broadcast frames taken and the checksum stripped;
/// `all` takes every frame there is, whoever it was for. A group that
/// was joined is taken by the multicast table instead, so nothing here
/// asks for every group's frames on their own.
pub fn startReceive(at: usize, all: bool) void {
    var control: u32 = rctl_en | rctl_bam | rctl_secrc;
    if (all) control |= rctl_upe | rctl_mpe;
    // The controller works out an arriving packet's checksums and says
    // in the descriptor whether they were right, which saves the opener
    // the sums over every byte it is handed.
    write(at, rxcsum, rxcsum_ip | rxcsum_transport);
    write(at, rctl, control);
}

pub fn stopReceive(at: usize) void {
    write(at, rctl, 0);
}

/// Sending on, with short frames padded. The gap between frames is left
/// as the controller set it.
pub fn startTransmit(at: usize) void {
    write(at, tctl, read(at, tctl) | tctl_en | tctl_psp);
}

pub fn stopTransmit(at: usize) void {
    write(at, tctl, read(at, tctl) & ~tctl_en);
}

// --- the PHY ----------------------------------------------------------------------

/// A PHY register written. False where the controller reports an error
/// or never finishes, which is what a part with no PHY at that address -
/// one whose medium is not copper - looks like.
pub fn mdioWrite(at: usize, number: u32, value: u16) bool {
    write(at, mdic, mdic_write | phy_address << mdic_phy_shift | number << mdic_reg_shift | value);
    return finished(at) != null;
}

/// The MDIC register once the transfer is done, or null where the
/// controller could not do it.
fn finished(at: usize) ?u32 {
    var tries: u32 = 0;
    while (tries < mdio_tries) : (tries += 1) {
        const word = read(at, mdic);
        if (word == 0xFFFF_FFFF or word & mdic_error != 0) return null;
        if (word & mdic_ready != 0) return word;
    }
    return null;
}

// --- the interrupt ----------------------------------------------------------------

/// Every cause on the one vector the driver asked for, and that vector
/// unmasked: the two queues through the vector allocation registers, and
/// a link that changed through the first block, which the controller
/// maps onto the extended cause `eicr_other`.
pub fn vectorInterrupts(at: usize, family: *const Family) void {
    write(at, gpie, gpie_nsicr | gpie_msix | gpie_eiame | gpie_pba);
    // The first byte of the first allocation register is receive queue
    // 0, the second send queue 0; the second byte of the misc register
    // is everything else.
    write(at, ivar0, ivar_valid | (ivar_valid << 8));
    write(at, ivar_misc, ivar_valid << 8);
    // No throttle: a frame should reach the task as soon as it is there.
    write(at, eitr0, 0);
    // The queues' causes clear themselves as the interrupt is taken; the
    // mapped ones are cleared by reading the cause register.
    write(at, eiac, 1);
    write(at, family.ims, cause_lsc);
    write(at, eims, 1 | eicr_other);
}

/// The same causes where the function has no vector of its own and
/// raises its interrupt line instead: then they are read from the first
/// block alone, and the extended registers stay out of it.
pub fn lineInterrupts(at: usize, family: *const Family) void {
    write(at, gpie, gpie_nsicr);
    write(at, family.ims, cause_lsc | cause_rxdw | cause_txdw | cause_rxo | cause_rxdmt0);
}

/// A cause raised by hand, so that the task comes and looks without
/// waiting for the hardware to raise it: the link's, once the causes are
/// turned on, so that a link which came up before anything was
/// listening is read all the same.
pub fn raise(at: usize, family: *const Family, causes: u32) void {
    write(at, family.ics, causes);
}

/// What the controller has raised, taken; null where it has raised
/// nothing, which is what an interrupt line shared with another
/// function looks like. Reading either cause register clears it: the
/// extended one says which vectors were raised, the first one says what
/// for, and both have to be cleared or the next one is never raised.
pub fn takeCauses(at: usize, family: *const Family) ?u32 {
    const vectors = read(at, eicr);
    const causes = read(at, family.icr);
    if (vectors == 0 and causes == 0) return null;
    return causes;
}
