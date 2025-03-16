const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const net = std.net;
const io = std.io;
const response = @import("./response.zig");
const SliceReader = @import("./SliceReader.zig");

// REGISTER sip:localhost SIP/2.0
// Via: SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh
// Max-Forwards: 70
// From: "Streats" <sip:streats@localhost>;tag=BXQAqfzJoJqWw3c9uJS71bwCq-WuaNtW
// To: "Streats" <sip:streats@localhost>
// Call-ID: jOyTomQC6PHEVeOXxOyxFV8drOmzbrs7
// CSeq: 13265 REGISTER
// User-Agent: Telephone 1.6
// Contact: "Streats" <sip:streats@192.168.1.130:54216;ob>
// Expires: 300
// Allow: PRACK, INVITE, ACK, BYE, CANCEL, UPDATE, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS
// Content-Length:  0

fn getHeaderValue(header_text: []const u8) []const u8 {
    var index: usize = 0;
    var quoted = false;
    var braced = false;
    for (header_text) |character| {
        if (character == '"') quoted = !quoted;
        if (character == '<') braced = true;
        if (character == '>') braced = false;

        if (!quoted and !braced and character == ';') break;
        index += 1;
    }

    return header_text[0..index];
}

//TODO does not handle escaped semicolons (\;)
fn getHeaderParamater(header_text: []const u8, attribute_name: []const u8) !?[]const u8 {
    if (attribute_name.len > 126) return response.SIPError.InvalidHeader;
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, ";{s}=", .{attribute_name});

    const _start = std.mem.indexOf(u8, header_text, needle) orelse return null;
    const start = _start + needle.len;

    const remainder = header_text[start..];
    if (std.mem.indexOfScalar(u8, remainder, ';')) |end| {
        return remainder[0..end];
    }
    return remainder;
}

const ContactProtocol = enum {
    sip,

    pub fn fromString(protocol: []const u8) !ContactProtocol {
        if (std.mem.eql(u8, protocol, "sip")) return ContactProtocol.sip;

        return response.SIPError.InvalidHeader;
    }

    pub fn toString(self: ContactProtocol) []const u8 {
        switch (self) {
            .sip => return "sip",
        }
    }
};

pub const Contact = struct {
    name: ?[]const u8, //Readable name
    protocol: ContactProtocol,
    user: []const u8,
    host: []const u8,
    port: u16,

    fn hostEnd(char: u8) bool {
        return char == '>' or char == ':' or char == ';';
    }

    fn portEnd(char: u8) bool {
        return char == '>' or char == ';';
    }

    /// Parses a contact in the following format
    /// ["Streats" <sip:streats@192.168.1.130:54216;ob>]
    fn parse(contact_text: []const u8) !Contact {
        var contact = Contact{
            .name = null,
            .protocol = undefined,
            .user = undefined,
            .host = undefined,
            .port = undefined,
        };
        var reader = SliceReader.init(contact_text);

        if (reader.peek() == '"') {
            _ = reader.get();
            contact.name = reader.readUntilScalarExcluding('"');
        }

        _ = reader.readUntilScalarExcluding('<');

        const protocol = reader.readUntilScalarExcluding(':');
        contact.protocol = try ContactProtocol.fromString(protocol);

        contact.user = reader.readUntilScalarExcluding('@');
        contact.host = reader.readUntil(hostEnd);
        contact.port = 5060; //TODO protocol.defaultPort()
        const host_end = reader.get() orelse return response.SIPError.InvalidHeader;
        if (host_end == ':') {
            const port_text = reader.readUntil(portEnd);
            contact.port = try fmt.parseInt(u16, port_text, 10);
        }

        return contact;
    }
};

test "Contact can parse with no name" {
    const contact = try Contact.parse("<sip:streats@localhost>");
    try std.testing.expect(contact.name == null);
    try std.testing.expect(contact.protocol == .sip);
    try std.testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try std.testing.expect(std.mem.eql(u8, contact.host, "localhost"));
    try std.testing.expect(contact.port == 5060);
}

test "Contact can parse with a name" {
    const contact = try Contact.parse("\"Streats\" <sip:streats@localhost>");
    try std.testing.expect(std.mem.eql(u8, contact.name.?, "Streats"));
    try std.testing.expect(contact.protocol == .sip);
    try std.testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try std.testing.expect(std.mem.eql(u8, contact.host, "localhost"));
    try std.testing.expect(contact.port == 5060);
}

test "Contact can parse with a port" {
    const contact = try Contact.parse("\"Streats\" <sip:streats@localhost:12345>");
    try std.testing.expect(std.mem.eql(u8, contact.name.?, "Streats"));
    try std.testing.expect(contact.protocol == .sip);
    try std.testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try std.testing.expect(std.mem.eql(u8, contact.host, "localhost"));
    try std.testing.expect(contact.port == 12345);
}

test "Contact can parse with attributes" {
    const contact = try Contact.parse("\"Streats\" <sip:streats@192.168.1.130:54216;ob>");
    try std.testing.expect(std.mem.eql(u8, contact.name.?, "Streats"));
    try std.testing.expect(contact.protocol == .sip);
    try std.testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try std.testing.expect(std.mem.eql(u8, contact.host, "192.168.1.130"));
    try std.testing.expect(contact.port == 54216);
}

const TransportProtocol = enum {
    udp,
    tcp,
    tls,
    sctp,
    ws,
    wss,

    pub fn fromString(protocol: []const u8) !TransportProtocol {
        const max_protocol_length = 64;
        if (protocol.len > max_protocol_length) return response.SIPError.InvalidHeader;

        var buffer: [max_protocol_length]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();

        const protocol_lower = try std.ascii.allocLowerString(allocator, protocol);
        defer allocator.free(protocol_lower);

        if (std.mem.eql(u8, protocol_lower, "udp")) return TransportProtocol.udp;
        if (std.mem.eql(u8, protocol_lower, "tcp")) return TransportProtocol.tcp;
        if (std.mem.eql(u8, protocol_lower, "tls")) return TransportProtocol.tls;
        if (std.mem.eql(u8, protocol_lower, "sctp")) return TransportProtocol.sctp;
        if (std.mem.eql(u8, protocol_lower, "ws")) return TransportProtocol.ws;
        if (std.mem.eql(u8, protocol_lower, "wss")) return TransportProtocol.wss;

        return response.SIPError.InvalidHeader;
    }

    pub fn toString(self: TransportProtocol) []const u8 {
        switch (self) {
            .udp => return "UDP",
            .tcp => return "TCP",
            .tls => return "TLS",
            .sctp => return "SCTP",
            .ws => return "WS",
            .wss => return "WSS",
        }
    }
};

pub const ViaHeader = struct {
    protocol: TransportProtocol,
    address: net.Address,
    branch: []const u8, //mandatory for UDP
    rport: ?u16,
    ttl: ?u32,
    received: ?[]const u8, //source ip of the request
    maddr: ?[]const u8, //multicast address
    sent_by: ?[]const u8, //sender address when using multicast

    // SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh
    // surely this can be improved...
    pub fn parse(header_text: []const u8) !ViaHeader {
        var via_header: ViaHeader = undefined;

        const header_value = getHeaderValue(header_text);

        //Assert we're using SIP/2.0
        var version_iter = mem.tokenizeScalar(u8, header_value, '/');
        const sip = version_iter.next() orelse return response.SIPError.InvalidHeader;
        const sip_stripped = std.mem.trim(u8, sip, " ");
        if (!mem.eql(u8, sip_stripped, "SIP")) return response.SIPError.InvalidHeader;

        const version = version_iter.next() orelse return response.SIPError.InvalidHeader;
        const version_stripped = std.mem.trim(u8, version, " ");
        if (!mem.eql(u8, version_stripped, "2.0")) return response.SIPError.InvalidHeader;

        //get the protocol
        const rest = version_iter.rest();
        const rest_stripped = mem.trim(u8, rest, " ");
        var value_iter = mem.tokenizeScalar(u8, rest_stripped, ' ');

        const protocol = value_iter.next() orelse return response.SIPError.InvalidHeader;
        via_header.protocol = try TransportProtocol.fromString(protocol);

        //get the address
        const address = value_iter.next() orelse return response.SIPError.InvalidHeader;
        var address_iter = std.mem.tokenizeScalar(u8, address, ':');

        const ip = address_iter.next() orelse return response.SIPError.InvalidHeader;
        const port_text = address_iter.next() orelse return response.SIPError.InvalidHeader;
        const port = try std.fmt.parseInt(u16, port_text, 10);

        via_header.address = try net.Address.parseIp(ip, port);

        //get attributes
        const magic_cookie = "z9hG4bK";
        via_header.branch = try getHeaderParamater(header_text, "branch") orelse return response.SIPError.InvalidHeader;
        if (!std.mem.startsWith(u8, via_header.branch, magic_cookie)) return response.SIPError.InvalidHeader;

        if (try getHeaderParamater(header_text, "rport")) |rport| {
            via_header.rport = try std.fmt.parseInt(u16, rport, 10);
        }

        if (try getHeaderParamater(header_text, "ttl")) |ttl| {
            via_header.ttl = try std.fmt.parseInt(u32, ttl, 10);
        }

        via_header.received = try getHeaderParamater(header_text, "received");
        via_header.maddr = try getHeaderParamater(header_text, "maddr");
        via_header.sent_by = try getHeaderParamater(header_text, "sent_by");

        return via_header;
    }
};

pub const FromHeader = struct {
    contact: Contact,
    tag: ?[]const u8,

    // pub fn parse(header_text: []const u8) !FromHeader {
    //     const contact_text = getHeaderValue(header_text);

    //     return FromHeader{
    //         .number = try std.fmt.parseInt(u32, number_text, 10),
    //         .tag = try getHeaderParamater(header_text, "tag"),
    //     };
    // }
};

pub const ToHeader = FromHeader;

pub const Sequence = struct {
    number: u32,
    method: Method,

    pub fn parse(header_text: []const u8) !Sequence {
        var iter = mem.tokenizeScalar(u8, header_text, ' ');

        const number_text = iter.next() orelse return response.SIPError.InvalidHeader;
        const method_text = iter.next() orelse return response.SIPError.InvalidHeader;

        return Sequence{
            .number = try std.fmt.parseInt(u32, number_text, 10),
            .method = try Method.fromString(method_text),
        };
    }
};

//TODO Status should really be an enum
pub fn statusCodeToString(status_code: u32) ![]const u8 {
    switch (status_code) {
        200 => return "OK",
        else => return response.SIPError.InvalidStatusCode,
    }
}

pub const Header = enum {
    via,
    max_forwards,
    from,
    to,
    call_id,
    cseq,
    user_agent,
    contact,
    expires,
    allow,
    content_length,

    pub fn fromString(field: []const u8) !Header {
        const max_field_length = 128;
        if (field.len > max_field_length) return response.SIPError.InvalidHeader;

        var buffer: [max_field_length]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();

        const field_lower = try std.ascii.allocLowerString(allocator, field);
        defer allocator.free(field_lower);

        if (std.mem.eql(u8, field_lower, "via")) return Header.via;
        if (std.mem.eql(u8, field_lower, "max-forwards")) return Header.max_forwards;
        if (std.mem.eql(u8, field_lower, "from")) return Header.from;
        if (std.mem.eql(u8, field_lower, "to")) return Header.to;
        if (std.mem.eql(u8, field_lower, "call-id")) return Header.call_id;
        if (std.mem.eql(u8, field_lower, "cseq")) return Header.cseq;
        if (std.mem.eql(u8, field_lower, "user-agent")) return Header.user_agent;
        if (std.mem.eql(u8, field_lower, "contact")) return Header.contact;
        if (std.mem.eql(u8, field_lower, "expires")) return Header.expires;
        if (std.mem.eql(u8, field_lower, "allow")) return Header.allow;
        if (std.mem.eql(u8, field_lower, "content-length")) return Header.content_length;

        return response.SIPError.InvalidHeader;
    }

    pub fn toString(self: Header) []const u8 {
        switch (self) {
            .via => return "Via",
            .max_forwards => return "Max-Forwards",
            .from => return "From",
            .to => return "To",
            .call_id => return "Call-ID",
            .cseq => return "CSeq",
            .user_agent => return "User-Agent",
            .contact => return "Contact",
            .expires => return "Expires",
            .allow => return "Allow",
            .content_length => return "Content-Length",
        }
    }
};
// Via: SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh
// Max-Forwards: 70
// From: "Streats" <sip:streats@localhost>;tag=BXQAqfzJoJqWw3c9uJS71bwCq-WuaNtW
// To: "Streats" <sip:streats@localhost>
// Call-ID: jOyTomQC6PHEVeOXxOyxFV8drOmzbrs7
// CSeq: 13265 REGISTER
// User-Agent: Telephone 1.6
// Contact: "Streats" <sip:streats@192.168.1.130:54216;ob>
// Expires: 300
// Allow: PRACK, INVITE, ACK, BYE, CANCEL, UPDATE, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS
// Content-Length:  0

pub const Method = enum {
    invite,
    ack,
    options,
    bye,
    cancel,
    register,
    subscribe,
    notify,
    publish,
    info,
    refer,
    message,
    update,
    prack,

    pub fn fromString(method: []const u8) !Method {
        if (std.mem.eql(u8, method, "INVITE")) return Method.invite;
        if (std.mem.eql(u8, method, "ACK")) return Method.ack;
        if (std.mem.eql(u8, method, "OPTIONS")) return Method.options;
        if (std.mem.eql(u8, method, "BYE")) return Method.bye;
        if (std.mem.eql(u8, method, "CANCEL")) return Method.cancel;
        if (std.mem.eql(u8, method, "REGISTER")) return Method.register;
        if (std.mem.eql(u8, method, "SUBSCRIBE")) return Method.subscribe;
        if (std.mem.eql(u8, method, "NOTIFY")) return Method.notify;
        if (std.mem.eql(u8, method, "PUBLISH")) return Method.publish;
        if (std.mem.eql(u8, method, "INFO")) return Method.info;
        if (std.mem.eql(u8, method, "REFER")) return Method.refer;
        if (std.mem.eql(u8, method, "MESSAGE")) return Method.message;
        if (std.mem.eql(u8, method, "UPDATE")) return Method.update;
        if (std.mem.eql(u8, method, "PRACK")) return Method.prack;
        return response.SIPError.InvalidMethod;
    }

    pub fn toString(self: Method) []const u8 {
        switch (self) {
            .invite => return "INVITE",
            .ack => return "ACK",
            .options => return "OPTIONS",
            .bye => return "BYE",
            .cancel => return "CANCEL",
            .register => return "REGISTER",
            .subscribe => return "SUBSCRIBE",
            .notify => return "NOTIFY",
            .publish => return "PUBLISH",
            .info => return "INFO",
            .refer => return "REFER",
            .message => return "MESSAGE",
            .update => return "UPDATE",
            .prack => return "PRACK",
        }
    }
};
