const std = @import("std");
const rtp = @import("./root.zig");

pub const RTP_L16 = struct {
    session: rtp.Session,

    pub fn init(allocator: *std.mem.Allocator) RTP_L16 {
        const session = rtp.Session.init(allocator, 11);

        return RTP_L16{
            .session = session,
        };
    }

    pub fn setSources(self: *RTP_L16, contrib_sources: []u32) !void {
        return try self.session.setSources(contrib_sources);
    }

    pub fn encodePacket(self: *RTP_L16, samples: []const i16, marker: bool) ![]u8 {
        const data = std.mem.sliceAsBytes(samples);
        return try self.session.encodePacket(data, @intCast(samples.len), marker, false);
    }
};
