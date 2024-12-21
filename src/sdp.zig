const std = @import("std");

const DescriptionError = error{
    UnexpectedField,
    InvalidField,
    InvalidVersion,
    InvalidOrigin,
};

pub const SDP = struct {
    version: []const u8,
    origin: Origin,
    name: []const u8,
    information: ?[]const u8,
    uri: ?std.Uri,
    email: ?[]const u8,
    phone: ?[]const u8,
    connectionInfo: ?ConnectionInfo,
};

pub fn parse(allocator: *std.mem.Allocator, description: []const u8) !SDP {
    _ = allocator;
    var sdp: SDP = undefined;
    var lines = std.mem.splitScalar(u8, description, '\n');
    var expected_field: []const u8 = "v";
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
                sdp.connectionInfo = parseConnectionInfo(line);
                expected_field = "bt";
            },
            else => return DescriptionError.UnexpectedField,
        }
    }

    return sdp;
}

fn parseVersion(line: []const u8) DescriptionError![]const u8 {
    if (!std.mem.eql(u8, line, "v=0")) return DescriptionError.InvalidVersion;
    return line[2..];
}

const Origin = struct {
    username: []const u8,
    session_id: u32,
    session_version: u32,
    address: std.net.Address,
};

// o=jdoe 2890844526 2890842807 IN IP4 10.47.16.5
// o=<username> <sess-id> <sess-version> <nettype> <addrtype> <unicast-address>
fn parseOrigin(line: []const u8) !Origin {
    var origin: Origin = undefined;
    var origin_tokens = std.mem.splitScalar(u8, line[2..], ' ');

    origin.username = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    const session_id = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    origin.session_id = try std.fmt.parseInt(u32, session_id, 10);
    const session_version = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    origin.session_version = try std.fmt.parseInt(u32, session_version, 10);

    const net_type = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    if (!std.mem.eql(u8, net_type, "IN")) return DescriptionError.InvalidOrigin;

    const address_type = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    const address = origin_tokens.next() orelse return DescriptionError.InvalidOrigin;
    if (std.mem.eql(u8, address_type, "IP4")) {
        origin.address = try std.net.Address.parseIp4(address, 0);
    } else if (std.mem.eql(u8, address_type, "IP6")) {
        origin.address = try std.net.Address.parseIp6(address, 0);
    } else return DescriptionError.InvalidOrigin;

    return origin;
}

fn parseName(line: []const u8) []const u8 {
    return line[2..];
}

fn parseInformation(line: []const u8) []const u8 {
    return line[2..];
}

fn parseUri(line: []const u8) DescriptionError![]const u8 {
    return try std.Uri.parse(line[2..]);
}

fn parseEmail(line: []const u8) []const u8 {
    return try line[2..];
}

fn parsePhone(line: []const u8) []const u8 {
    return try line[2..];
}

const ConnectionInfo = struct {};

fn parseConnectionInfo(line: []const u8) !ConnectionInfo {}

test "SDP parse accepts valid session description" {
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
    const session_desc = try parse(&allocator, description);
    try std.testing.expect(std.mem.eql(u8, session_desc.version, "0"));
}
