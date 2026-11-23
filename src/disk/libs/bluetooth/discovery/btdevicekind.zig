// SPDX-License-Identifier: MIT
//! BTDeviceKind: what a device is, read from the class of device a
//! BR/EDR device sends or the appearance an LE device advertises.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Says what a device is, as one of the kinds programs name.
///
/// SYNOPSIS:
/// ```zig
/// fn BTDeviceKind(base: *BluetoothBase, class_of_device: u32, appearance: u32) u32
/// ```
///
/// SINCE: 1.11. LVO -180.
///
/// INPUTS:
/// - `class_of_device` - BTDevice.class_of_device, BTBond's or
///   BTConnection's: the major and minor class in its low 13 bits; 0 for
///   none.
/// - `appearance` - BTDevice.appearance: an LE device's category in its
///   bits 6 to 15, the subcategory below; 0 for none.
///
/// RESULT:
/// BTDK_*: what the device is; BTDK_NONE where it says neither.
///
/// BEHAVIOR:
/// The class of device is read first: its major class, and where that
/// tells kinds apart, its minor class - a laptop from a computer,
/// headphones from a headset, a keyboard from a mouse or both in one, a
/// gamepad from a joystick. A class that names no kind (miscellaneous,
/// uncategorized) leaves the appearance to say it: its subcategory where
/// it names a kind (a keyboard, a mouse, earbuds), else its category. A
/// class or a category this library does not know is BTDK_NONE, and so
/// are both 0.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes - it reads nothing but its inputs.
/// - Locks: any may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is handed over.
///
/// NOTES:
/// A kind is a number, for the program to name in its own words and
/// language. A kind past the ones a program names is shown as it shows
/// BTDK_NONE; BTDK_LAST is the highest there is.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainBTDevices`, `ObtainBTBonds`, `ObtainBTConnections`
///
/// EXAMPLES:
/// ```zig
/// const kind = bt.BTDeviceKind(found.class_of_device, found.appearance);
/// if (kind == bluetooth.BTDK_KEYBOARD) ... ;
/// ```
pub fn BTDeviceKind(_: *BluetoothBase, class_of_device: u32, appearance: u32) u32 {
    const by_class = ofClass(class_of_device);
    if (by_class != bluetooth.BTDK_NONE) return by_class;
    return ofAppearance(appearance);
}

/// The kind a class of device's major and minor classes name.
fn ofClass(class_of_device: u32) u32 {
    if (class_of_device == 0) return bluetooth.BTDK_NONE;
    const major = (class_of_device >> 8) & 0x1F;
    const minor = (class_of_device >> 2) & 0x3F;
    return switch (major) {
        hci.COD_MAJOR_COMPUTER => switch (minor) {
            hci.COD_COMPUTER_LAPTOP => bluetooth.BTDK_LAPTOP,
            hci.COD_COMPUTER_HANDHELD => bluetooth.BTDK_HANDHELD,
            else => bluetooth.BTDK_COMPUTER,
        },
        hci.COD_MAJOR_PHONE => bluetooth.BTDK_PHONE,
        hci.COD_MAJOR_NETWORK => bluetooth.BTDK_ACCESS_POINT,
        hci.COD_MAJOR_AUDIO_VIDEO => switch (minor) {
            1 => bluetooth.BTDK_HEADSET,
            2 => bluetooth.BTDK_HANDS_FREE,
            4 => bluetooth.BTDK_MICROPHONE,
            5 => bluetooth.BTDK_LOUDSPEAKER,
            6 => bluetooth.BTDK_HEADPHONES,
            7 => bluetooth.BTDK_PORTABLE_AUDIO,
            8 => bluetooth.BTDK_CAR_AUDIO,
            10 => bluetooth.BTDK_HIFI,
            14, 15 => bluetooth.BTDK_DISPLAY,
            18 => bluetooth.BTDK_GAME_CONSOLE,
            else => bluetooth.BTDK_AUDIO_VIDEO,
        },
        // The minor class's top two bits: a keyboard, a pointing device or
        // both; its low four what else it is.
        hci.COD_MAJOR_PERIPHERAL => switch (minor >> 4) {
            1 => bluetooth.BTDK_KEYBOARD,
            2 => bluetooth.BTDK_MOUSE,
            3 => bluetooth.BTDK_KEYBOARD_MOUSE,
            else => switch (minor & 0xF) {
                1 => bluetooth.BTDK_JOYSTICK,
                2 => bluetooth.BTDK_GAMEPAD,
                3 => bluetooth.BTDK_REMOTE,
                5 => bluetooth.BTDK_TABLET,
                else => bluetooth.BTDK_PERIPHERAL,
            },
        },
        hci.COD_MAJOR_IMAGING => bluetooth.BTDK_IMAGING,
        hci.COD_MAJOR_WEARABLE => bluetooth.BTDK_WEARABLE,
        hci.COD_MAJOR_TOY => bluetooth.BTDK_TOY,
        hci.COD_MAJOR_HEALTH => bluetooth.BTDK_HEALTH,
        else => bluetooth.BTDK_NONE,
    };
}

/// The kind an LE appearance names: a subcategory that names one, else
/// its category.
fn ofAppearance(appearance: u32) u32 {
    return switch (appearance & 0xFFFF) {
        0 => bluetooth.BTDK_NONE,
        0x0083 => bluetooth.BTDK_LAPTOP,
        0x0084 => bluetooth.BTDK_HANDHELD,
        0x03C1 => bluetooth.BTDK_KEYBOARD,
        0x03C2 => bluetooth.BTDK_MOUSE,
        0x03C3 => bluetooth.BTDK_JOYSTICK,
        0x03C4 => bluetooth.BTDK_GAMEPAD,
        0x03C5 => bluetooth.BTDK_TABLET,
        0x0941 => bluetooth.BTDK_EARBUDS,
        0x0942 => bluetooth.BTDK_HEADSET,
        0x0943 => bluetooth.BTDK_HEADPHONES,
        else => switch ((appearance & 0xFFFF) >> 6) {
            1 => bluetooth.BTDK_PHONE,
            2 => bluetooth.BTDK_COMPUTER,
            3 => bluetooth.BTDK_WATCH,
            4 => bluetooth.BTDK_CLOCK,
            5 => bluetooth.BTDK_DISPLAY,
            6 => bluetooth.BTDK_REMOTE,
            8 => bluetooth.BTDK_TAG,
            9 => bluetooth.BTDK_KEYRING,
            10 => bluetooth.BTDK_MEDIA_PLAYER,
            12 => bluetooth.BTDK_THERMOMETER,
            13 => bluetooth.BTDK_HEART_RATE,
            15 => bluetooth.BTDK_PERIPHERAL,
            21 => bluetooth.BTDK_SENSOR,
            22, 31 => bluetooth.BTDK_LIGHT,
            33 => bluetooth.BTDK_LOUDSPEAKER,
            34 => bluetooth.BTDK_AUDIO_SOURCE,
            37 => bluetooth.BTDK_HEADPHONES,
            41 => bluetooth.BTDK_HEARING_AID,
            42 => bluetooth.BTDK_GAME_CONSOLE,
            else => bluetooth.BTDK_NONE,
        },
    };
}
