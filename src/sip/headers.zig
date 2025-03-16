const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const net = std.net;
const io = std.io;
const response = @import("./response.zig");
const SliceReader = @import("./SliceReader.zig");

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

    return std.mem.trim(u8, header_text[0..index], " ");
}

//TODO does not handle escaped semicolons (\;)
fn getHeaderParamater(header_text: []const u8, attribute_name: []const u8) !?[]const u8 {
    if (attribute_name.len > 126) return response.SIPError.InvalidHeader;
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, ";{s}=", .{attribute_name});

    const _start = std.mem.indexOf(u8, header_text, needle) orelse return null;
    const start = _start + needle.len;

    var remainder = header_text[start..];
    if (std.mem.indexOfScalar(u8, remainder, ';')) |end| {
        remainder = remainder[0..end];
    }
    return std.mem.trim(u8, remainder, " \n");
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

    fn addressEnd(char: u8) bool {
        return char == '>' or char == ';';
    }

    /// Parses a contact in the following format
    /// ["Streats" <sip:streats@192.168.1.130:54216;ob>]
    pub fn parse(contact_text: []const u8) !Contact {
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

        const address_text = reader.readUntil(addressEnd);
        const address = try Address.parse(address_text);
        contact.host = address.host;
        contact.port = address.port;

        return contact;
    }
};

//TODO use above in Contact
pub const Address = struct {
    host: []const u8,
    port: u16,

    /// Parses an address in the following format
    /// [192.168.1.130:54216]
    pub fn parse(address_text: []const u8) !Address {
        var reader = SliceReader.init(address_text);

        const host = reader.readUntilScalarExcluding(':');
        var port: u16 = 5060;
        const port_text = reader.rest();
        if (port_text.len > 0) port = try fmt.parseInt(u16, port_text, 10);

        return Address{
            .host = host,
            .port = port,
        };
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
    address: Address,
    branch: []const u8, //mandatory for UDP
    rport: ?u16,
    ttl: ?u32,
    received: ?[]const u8, //source ip of the request
    maddr: ?[]const u8, //multicast address
    sent_by: ?[]const u8, //sender address when using multicast

    fn isWhitespace(char: u8) bool {
        return char == ' ' or char == '\n' or char == '\t';
    }

    fn isTransport(char: u8) bool {
        if (char >= 'A' and char <= 'Z') return true;
        if (char >= 'a' and char <= 'z') return true;
        if (char >= '0' and char <= '9') return true;
        if (char == '.') return true;
        return false;
    }

    //SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh
    pub fn parse(header_text: []const u8) !ViaHeader {
        var via_header: ViaHeader = undefined;
        const header_value = getHeaderValue(header_text);
        var reader = SliceReader.init(header_value);

        const sip = reader.readWhile(isTransport);
        if (!mem.eql(u8, sip, "SIP")) return response.SIPError.InvalidHeader;

        _ = reader.readUntil(isTransport);
        const version = reader.readWhile(isTransport);
        if (!mem.eql(u8, version, "2.0")) return response.SIPError.InvalidHeader;

        _ = reader.readUntil(isTransport);
        const protocol = reader.readWhile(isTransport);
        if (!mem.eql(u8, protocol, "UDP")) return response.SIPError.InvalidHeader;
        via_header.protocol = try TransportProtocol.fromString(protocol);

        const address_text = std.mem.trimLeft(u8, reader.rest(), " ");
        via_header.address = try Address.parse(address_text);

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

test "ViaHeader parses values into fields" {
    const header_text = "SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh";
    const via = try ViaHeader.parse(header_text);

    try std.testing.expect(via.protocol == .udp);
    try std.testing.expect(std.mem.eql(u8, via.address.host, "192.168.1.130"));
    try std.testing.expect(via.address.port == 54216);
    try std.testing.expect(std.mem.eql(u8, via.branch, "z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh"));
}

test "ViaHeader parses with whitespace" {
    const header_text = "SIP / 2.0 / UDP first.example.com:4000 ;ttl=16\n;maddr=224.2.0.1 ;branch=z9hG4bKa7c6a8dlze.1";
    const via = try ViaHeader.parse(header_text);

    try std.testing.expect(via.protocol == .udp);
    try std.testing.expect(std.mem.eql(u8, via.address.host, "first.example.com"));
    try std.testing.expect(via.address.port == 4000);
    try std.testing.expect(via.ttl == 16);
    try std.testing.expect(std.mem.eql(u8, via.maddr.?, "224.2.0.1"));
    try std.testing.expect(std.mem.eql(u8, via.branch, "z9hG4bKa7c6a8dlze.1"));
}

pub const FromHeader = struct {
    contact: Contact,
    tag: ?[]const u8,

    pub fn parse(header_text: []const u8) !FromHeader {
        const contact_text = getHeaderValue(header_text);

        return FromHeader{
            .contact = try Contact.parse(contact_text),
            .tag = try getHeaderParamater(header_text, "tag"),
        };
    }
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
