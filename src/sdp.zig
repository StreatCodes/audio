const std = @import("std");

const DescriptionError = error{
    UnexpectedField,
    InvalidField,
};

const Field = struct {
    key: u8,
    required: bool,
    multi: bool,
};

const session_descriptions = [_]Field{
    .{ .key = 'v', .required = true, .multi = false }, //protocol version
    .{ .key = 'o', .required = true, .multi = false }, //originator and session identifier
    .{ .key = 's', .required = true, .multi = false }, //session name
    .{ .key = 'i', .required = false, .multi = false }, //session information
    .{ .key = 'u', .required = false, .multi = false }, //URI of description
    .{ .key = 'e', .required = false, .multi = false }, //email address
    .{ .key = 'p', .required = false, .multi = false }, //phone number
    .{ .key = 'c', .required = false, .multi = false }, //connection information - not required if included in all media
    .{ .key = 'b', .required = false, .multi = true }, //zero or more bandwidth information lines
    //One or more time descriptions
    .{ .key = 'z', .required = false, .multi = false }, //time zone adjustments
    .{ .key = 'k', .required = false, .multi = false }, //encryption key
    .{ .key = 'a', .required = false, .multi = true }, //zero or more session attribute lines
    //Zero or more media descriptions
};

const time_descriptions = [_]Field{
    .{ .key = 't', .required = true, .multi = false }, //time the session is active
    .{ .key = 'r', .required = false, .multi = true }, //zero or more repeat times
};

const media_descriptions = [_]Field{
    .{ .key = 'm', .required = true, .multi = false }, //media name and transport address
    .{ .key = 'i', .required = false, .multi = false }, //media title
    .{ .key = 'c', .required = false, .multi = false }, //connection information - optional if included at session level
    .{ .key = 'b', .required = false, .multi = true }, //zero or more bandwidth information lines
    .{ .key = 'k', .required = false, .multi = false }, //encryption key
    .{ .key = 'a', .required = false, .multi = true }, //zero or more media attribute lines
};

pub const SDP = struct {
    version: []const u8,
};

pub fn parse(allocator: *std.mem.Allocator, description: []const u8) DescriptionError!SDP {
    _ = allocator;
    var sdp: SDP = undefined;
    var lines = std.mem.splitScalar(u8, description, '\n');
    var expected_field: []const u8 = "v";
    while (lines.next()) |line| {
        switch (line[0]) {
            'v' => {
                if (std.mem.indexOfScalar(u8, expected_field, 'v') == null) {
                    return DescriptionError.UnexpectedField;
                }
                sdp.version = try parseVersion(line);
                expected_field = "o";
            },
            else => {},
        }
    }

    return sdp;
}

fn parseVersion(version_line: []const u8) DescriptionError![]const u8 {
    if (!std.mem.eql(u8, version_line, "v=0")) return DescriptionError.InvalidField;
    return version_line[2..];
}

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
