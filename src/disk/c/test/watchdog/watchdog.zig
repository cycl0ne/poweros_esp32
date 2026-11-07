// SPDX-License-Identifier: MIT
//! watchdog: watchdog.resource from the shell, for a machine reached over
//! the network, where the ROM debugger's `wdt` is out of reach.
//!
//!   watchdog                 its state
//!   watchdog ARM 15000       a reset after 15 s without a feed
//!   watchdog FEED            the armed time started over
//!   watchdog OFF             stopped
//!
//! Arming it and feeding it no more is how the watchdog is proved: the
//! machine resets once the time is up. Built against the SDK only.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const WatchdogBase = sdk.interface.watchdog.WatchdogBase;
const watchdog = sdk.resources.watchdog;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

const NAME = "watchdog";
const VERSION_STRING = "\x00$VER: watchdog 1.0 (07.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ARM/K/N,FEED/S,OFF/S";
const arg_arm = 0;
const arg_feed = 1;
const arg_off = 2;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // A resource is never closed: OpenResource only finds it.
    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "no %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (rdargs.number(argv[arg_arm])) |given| {
        const millis: u32 = if (given > 0) @intCast(given) else 0;
        if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
            _ = Printf(dl, "ArmWatchdog %d ms: refused\n", .{given});
            return dos.RETURN_ERROR;
        }
    } else if (argv[arg_feed] != 0) {
        wb.FeedWatchdog();
    } else if (argv[arg_off] != 0) {
        wb.DisarmWatchdog();
    }
    const armed = wb.ReadWatchdog();
    if (armed == 0) {
        _ = dl.PutStr("watchdog off\n");
    } else {
        _ = Printf(dl, "watchdog armed: a reset after %u ms without a feed\n", .{armed});
    }
    return dos.RETURN_OK;
}
