const std = @import("std");
const testing = std.testing;

const SessionError = error{TooManyContribSources};

const Header = packed struct {
    version: u2,
    padding: u1,
    extension: u1,
    contrib_count: u4,
    marker: u1,
    payload_type: u7,
    sequence: u16,
    timestamp: u32,
    sync_source: u32,
};

const Extension = struct {
    id: u16,
    data: []const u8,
};

pub const Session = struct {
    allocator: *std.mem.Allocator,
    payload_type: u7,
    sequence: u16,
    timestamp: u32,
    sync_source: u32,
    contrib_sources: []u32 = &[_]u32{},
    extension: ?Extension = null,

    pub fn init(allocator: *std.mem.Allocator, payload_type: u7) Session {
        return Session{
            .allocator = allocator,
            .payload_type = payload_type,
            .sequence = std.crypto.random.int(u16),
            .timestamp = std.crypto.random.int(u32),
            .sync_source = std.crypto.random.int(u32),
        };
    }

    /// Sets the contributing sources for the session. There is a maximum source
    /// limit of 16
    pub fn setSources(session: *Session, contrib_sources: []u32) SessionError!void {
        if (contrib_sources.len > 16) {
            return SessionError.TooManyContribSources;
        }
        session.contrib_sources = contrib_sources;
    }

    /// Sets the extension for the session.
    pub fn setExtensions(session: *Session, id: u16, extension_data: []const u8) void {
        session.extension = Extension{
            .id = id,
            .data = extension_data,
        };
    }

    /// Encodes bytes into a new RTP wire format packet. The caller is responsible
    /// for freeing the returned slice.
    pub fn encodePacket(session: *Session, bytes: []const u8, timer_increment: u32, marker: bool, padding: bool) ![]u8 {
        const sequence_over = @addWithOverflow(session.sequence, 1);
        session.sequence = sequence_over[0];
        const timestamp_over = @addWithOverflow(session.timestamp, timer_increment);
        const timestamp = timestamp_over[0];

        const contrib_count = session.contrib_sources.len;

        const header = Header{
            .version = 2,
            .padding = if (padding) 1 else 0,
            .extension = 0,
            .contrib_count = @intCast(contrib_count),
            .marker = if (marker) 1 else 0,
            .payload_type = session.payload_type,
            .sequence = session.sequence,
            .timestamp = timestamp,
            .sync_source = session.sync_source,
        };

        const sources_data = std.mem.sliceAsBytes(session.contrib_sources);

        var extension_len: usize = 0;
        if (session.extension != null) extension_len = 4 + session.extension.?.data.len;

        const buffer_size = @sizeOf(Header) + sources_data.len + extension_len + bytes.len;
        const buffer = try session.allocator.alloc(u8, buffer_size);
        var buffer_stream = std.io.fixedBufferStream(buffer);
        var buffer_writer = buffer_stream.writer();

        try buffer_writer.writeStruct(header);
        try buffer_writer.writeAll(sources_data);

        if (session.extension != null) {
            try buffer_writer.writeInt(u16, session.extension.?.id, std.builtin.Endian.big);
            try buffer_writer.writeInt(u16, @intCast(session.extension.?.data.len), std.builtin.Endian.big);
            try buffer_writer.writeAll(session.extension.?.data);
        }

        try buffer_writer.writeAll(bytes);

        return buffer;
    }
};

// this test is pretty bad
test "Check extension and data are present" {
    var allocator = testing.allocator;
    const contribs = [_]u32{};
    const data = [_]u8{'?'};
    var session = Session.init(&allocator, 50);
    try session.setSources(&contribs);

    const extension_data = "Some extension data!";
    session.setExtensions(1337, extension_data);

    const packet = try session.encodePacket(&data, 1, false, false);
    defer allocator.free(packet);

    const data_offset = packet.len - extension_data.len - 1;
    try testing.expect(std.mem.eql(u8, "Some extension data!?", packet[data_offset..]));
}
