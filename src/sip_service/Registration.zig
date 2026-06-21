const std = @import("std");

expires: u32 = 0,
registered_at: std.Io.Timestamp,
connection: std.Io.net.Socket,

// TODO send message fn
