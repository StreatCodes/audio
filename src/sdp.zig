const std = @import("std");

const DescriptionError = error{
    UnexpectedField,
    InvalidField,
    InvalidVersion,
    InvalidOrigin,
    InvalidConnectionInfo,
    InvalidTime,
};

const Origin = struct {
    username: []const u8,
    session_id: u32,
    session_version: u32,
    address: std.net.Address,
};

const Time = struct {
    start: u64,
    end: u64,
};

pub const SDP = struct {
    allocator: *std.mem.Allocator,
    version: []const u8,
    origin: Origin,
    name: []const u8,
    information: ?[]const u8,
    uri: ?std.Uri,
    email: ?[]const u8,
    phone: ?[]const u8,
    connectionInfo: ?std.net.Address,
    bandwidth: ?[]const u8,
    times: []Time,

    fn deinit(self: *SDP) void {
        self.allocator.free(self.times);
    }
};

pub fn parse(allocator: *std.mem.Allocator, description: []const u8) !SDP {
    var sdp: SDP = undefined;
    sdp.allocator = allocator;

    var lines = std.mem.splitScalar(u8, description, '\n');
    var expected_field: []const u8 = "v";
    var times = std.ArrayList(Time).init(allocator.*);
    while (lines.next()) |line| {
        const field = line[0];
        if (std.mem.indexOfScalar(u8, expected_field, field) == null) {
            std.debug.print("Expected {s} got {c}\n", .{ expected_field, field });
            return DescriptionError.UnexpectedField;
        }
        if (line.len < 3 or line[1] != '=') return DescriptionError.InvalidField;

        switch (field) {
            'v' => {
                sdp.version = try parseVersion(line);
                expected_field = "o";
            },
            'o' => {
                sdp.origin = try parseOrigin(line);
                expected_field = "s";
            },
            's' => {
                sdp.name = parseName(line);
                expected_field = "iuepcbt";
            },
            'i' => {
                sdp.information = parseInformation(line);
                expected_field = "uepcbt";
            },
            'u' => {
                sdp.uri = try parseUri(line);
                expected_field = "epcbt";
            },
            'e' => {
                sdp.email = parseEmail(line);
                expected_field = "pcbt";
            },
            'p' => {
                sdp.phone = parsePhone(line);
                expected_field = "cbt";
            },
            'c' => {
                sdp.connectionInfo = try parseConnectionInfo(line);
                expected_field = "bt";
            },
            'b' => {
                sdp.bandwidth = parseBandwidth(line);
                expected_field = "bt";
            },
            't' => {
                const time = try parseTime(line);
                try times.append(time);
                expected_field = "trkam";
            },
            'r' => {
                //TODO implement
                expected_field = "tzkam";
            },
            'z' => {
                //TODO implement
                expected_field = "tkam";
            },
            'k' => {
                expected_field = "am";
            },
            'a' => {
                //TODO implement
                expected_field = "am";
            },
            'm' => {
                // TODO implement
                expected_field = "micbka";
            },
            else => return DescriptionError.UnexpectedField,
        }
    }

    sdp.times = try times.toOwnedSlice();
    return sdp;
}

fn parseVersion(line: []const u8) DescriptionError![]const u8 {
    if (!std.mem.eql(u8, line, "v=0")) return DescriptionError.InvalidVersion;
    return line[2..];
}

fn readConnection(conn_string: []const u8) !std.net.Address {
    var conn_tokens = std.mem.splitScalar(u8, conn_string, ' ');
    const net_type = conn_tokens.next() orelse return DescriptionError.InvalidConnectionInfo;
    if (!std.mem.eql(u8, net_type, "IN")) return DescriptionError.InvalidConnectionInfo;

    const address_type = conn_tokens.next() orelse return DescriptionError.InvalidConnectionInfo;
    const address = conn_tokens.next() orelse return DescriptionError.InvalidConnectionInfo;
    if (std.mem.eql(u8, address_type, "IP4")) {
        //Remove TTL for multicast addresses, support this somehow in future.
        var end = address.len;
        const ttl = std.mem.indexOfScalar(u8, address, '/');
        if (ttl != null) end = ttl.?;

        return try std.net.Address.parseIp4(address[0..end], 0);
    } else if (std.mem.eql(u8, address_type, "IP6")) {
        return try std.net.Address.parseIp6(address, 0);
    } else return DescriptionError.InvalidConnectionInfo;
}

fn parseOrigin(line: []const u8) !Origin {
    var origin: Origin = undefined;
    var origin_tokens = std.mem.splitScalar(u8, line[2..], ' ');

    origin.username = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    const session_id = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    origin.session_id = try std.fmt.parseInt(u32, session_id, 10);
    const session_version = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    origin.session_version = try std.fmt.parseInt(u32, session_version, 10);

    origin.address = try readConnection(origin_tokens.rest());

    return origin;
}

fn parseName(line: []const u8) []const u8 {
    return line[2..];
}

fn parseInformation(line: []const u8) []const u8 {
    return line[2..];
}

fn parseUri(line: []const u8) !std.Uri {
    return try std.Uri.parse(line[2..]);
}

fn parseEmail(line: []const u8) []const u8 {
    return line[2..];
}

fn parsePhone(line: []const u8) []const u8 {
    return line[2..];
}

fn parseConnectionInfo(line: []const u8) !std.net.Address {
    return try readConnection(line[2..]);
}

fn parseBandwidth(line: []const u8) []const u8 {
    return line[2..];
}

fn parseTime(line: []const u8) !Time {
    var time: Time = undefined;
    var tokens = std.mem.splitScalar(u8, line[2..], ' ');
    const start_text = tokens.next() orelse return DescriptionError.InvalidTime;
    const end_text = tokens.next() orelse return DescriptionError.InvalidTime;

    time.start = try std.fmt.parseInt(u64, start_text, 10);
    time.end = try std.fmt.parseInt(u64, end_text, 10);

    //Convert seconds since January 1, 1900 UTC to unix
    if (time.start > 2208988800) time.start -= 2208988800;
    if (time.end > 2208988800) time.end -= 2208988800;

    return time;
}

test "SDP parse accepts RFC example session" {
    const description =
        \\v=0
        \\o=jdoe 2890844526 2890842807 IN IP4 10.47.16.5
        \\s=SDP Seminar
        \\i=A Seminar on the session description protocol
        \\u=http://www.example.com/seminars/sdp.pdf
        \\e=j.doe@example.com (Jane Doe)
        \\c=IN IP4 224.2.17.12/127
        \\t=2873397496 2873404696
        \\a=recvonly
        \\m=audio 49170 RTP/AVP 0
        \\m=video 51372 RTP/AVP 99
        \\a=rtpmap:99 h263-1998/90000
    ;

    var allocator = std.testing.allocator;
    var session_desc = try parse(&allocator, description);
    defer session_desc.deinit();

    try std.testing.expect(std.mem.eql(u8, session_desc.version, "0"));
}

test "SDP parse accepts basic session description" {
    const description =
        \\v=0
        \\o=- 12345 1 IN IP4 192.168.1.1
        \\s=Basic Audio Session
        \\c=IN IP4 203.0.113.1
        \\t=1695537600 1695541200
        \\m=audio 5004 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
    ;

    var allocator = std.testing.allocator;
    var session_desc = try parse(&allocator, description);
    defer session_desc.deinit();

    try std.testing.expect(std.mem.eql(u8, session_desc.version, "0"));
}

test "SDP parse accepts video session with bandwidth limitations" {
    const description =
        \\v=0
        \\o=- 54321 2 IN IP4 192.168.1.2
        \\s=Video Streaming Session
        \\c=IN IP4 203.0.113.2
        \\b=AS:1024
        \\t=1695624000 1695627600
        \\m=video 6006 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=fmtp:96 profile-level-id=42E01E; packetization-mode=1
    ;

    var allocator = std.testing.allocator;
    var session_desc = try parse(&allocator, description);
    defer session_desc.deinit();

    try std.testing.expect(std.mem.eql(u8, session_desc.version, "0"));
}

test "SDP parse accepts multiple media streams" {
    const description =
        \\v=0
        \\o=- 98765 3 IN IP4 10.0.0.1
        \\s=Multi-Media Session
        \\c=IN IP4 203.0.113.3
        \\t=1695710400 1695714000
        \\m=audio 4000 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
        \\m=video 4002 RTP/AVP 97
        \\a=rtpmap:97 VP8/90000
        \\m=text 4004 RTP/AVP 98
        \\a=rtpmap:98 T140/1000
    ;

    var allocator = std.testing.allocator;
    var session_desc = try parse(&allocator, description);
    defer session_desc.deinit();

    try std.testing.expect(std.mem.eql(u8, session_desc.version, "0"));
}

test "SDP parse accepts multiple time periods" {
    const description =
        \\v=0
        \\o=- 11223 4 IN IP4 203.0.113.4
        \\s=Scheduled Meeting
        \\c=IN IP4 203.0.113.4
        \\t=1695537600 1695541200
        \\r=604800 3600 0 0
        \\t=1695624000 1695627600
        \\m=audio 5000 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
    ;

    var allocator = std.testing.allocator;
    var session_desc = try parse(&allocator, description);
    defer session_desc.deinit();

    try std.testing.expect(std.mem.eql(u8, session_desc.version, "0"));
}

test "SDP parse accepts channel with ICE candidates" {
    const description =
        \\v=0
        \\o=- 13579 1 IN IP4 192.0.2.1
        \\s=WebRTC Data Channel
        \\c=IN IP4 0.0.0.0
        \\t=0 0
        \\a=group:BUNDLE 0
        \\a=ice-ufrag:abcd1234
        \\a=ice-pwd:efgh5678
        \\m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        \\a=sctp-port:5000
    ;

    var allocator = std.testing.allocator;
    var session_desc = try parse(&allocator, description);
    defer session_desc.deinit();

    try std.testing.expect(std.mem.eql(u8, session_desc.version, "0"));
}
