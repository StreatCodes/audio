const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const net = std.net;
const io = std.io;
const testing = std.testing;
const SliceReader = @import("./SliceReader.zig");

pub const HeaderError = error{
    InvalidMethod,
    InvalidHeader,
};

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
fn getHeaderParameter(header_text: []const u8, attribute_name: []const u8) !?[]const u8 {
    if (attribute_name.len > 126) return HeaderError.InvalidHeader;
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

        return HeaderError.InvalidHeader;
    }

    pub fn toString(self: ContactProtocol) []const u8 {
        switch (self) {
            .sip => return "sip",
        }
    }
};

pub const ContactHeader = struct {
    contact: Contact,
    expires: ?u32,

    pub fn parse(header_text: []const u8) !ContactHeader {
        const header_value = getHeaderValue(header_text);
        var contact_header = ContactHeader{
            .contact = try Contact.parse(header_value),
            .expires = undefined,
        };

        if (try getHeaderParameter(header_text, "expires")) |expires_text| {
            contact_header.expires = try fmt.parseInt(u32, expires_text, 10);
        }

        return contact_header;
    }

    //"Streats" <sip:streats@192.168.1.130:54216>;expires=3000
    pub fn encode(self: ContactHeader, writer: anytype) !void {
        try self.contact.encode(writer);
        if (self.expires) |expires| try writer.print(";expires={d}", .{expires});
        try writer.writeAll("\r\n");
    }
};

//TODO contacts can include parameters too
pub const Contact = struct {
    name: ?[]const u8 = null, //Readable name
    protocol: ContactProtocol,
    user: []const u8,
    host: []const u8,
    port: ?u16 = null,
    ob: bool = false,

    fn addressEnd(char: u8) bool {
        return char == '>' or char == ';';
    }

    /// Parses a contact in the following format
    /// ["Streats" <sip:streats@192.168.1.130:54216;ob>]
    pub fn parse(contact_text: []const u8) !Contact {
        var contact = Contact{
            .protocol = undefined,
            .user = undefined,
            .host = undefined,
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

        const parameter_text = reader.readUntilScalar('>');
        if (parameter_text.len > 0) {
            //TODO need more robust way of checking boolean parameters
            //This will fail if more than one params are present
            if (mem.eql(u8, parameter_text, ";ob")) {
                contact.ob = true;
            }
        }

        return contact;
    }

    //"Streats" <sip:streats@192.168.1.130:54216>
    pub fn encode(self: Contact, writer: anytype) !void {
        if (self.name) |name| try writer.print("\"{s}\" ", .{name});
        try writer.print("<{s}:{s}@{s}", .{ self.protocol.toString(), self.user, self.host });
        if (self.port) |port| {
            //TODO convert to switch when we have other protocols
            if (self.protocol == .sip and self.port != 5060) {
                try writer.print(":{d}", .{port});
            }
        }
        if (self.ob) {
            try writer.writeAll(";ob");
        }
        _ = try writer.writeByte('>');
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
    try testing.expect(contact.name == null);
    try testing.expect(contact.protocol == .sip);
    try testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try testing.expect(std.mem.eql(u8, contact.host, "localhost"));
    try testing.expect(contact.port == 5060);
}

test "Contact can parse with a name" {
    const contact = try Contact.parse("\"Streats\" <sip:streats@localhost>");
    try testing.expect(std.mem.eql(u8, contact.name.?, "Streats"));
    try testing.expect(contact.protocol == .sip);
    try testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try testing.expect(std.mem.eql(u8, contact.host, "localhost"));
    try testing.expect(contact.port == 5060);
}

test "Contact can parse with a port" {
    const contact = try Contact.parse("\"Streats\" <sip:streats@localhost:12345>");
    try testing.expect(std.mem.eql(u8, contact.name.?, "Streats"));
    try testing.expect(contact.protocol == .sip);
    try testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try testing.expect(std.mem.eql(u8, contact.host, "localhost"));
    try testing.expect(contact.port == 12345);
}

test "Contact can parse with attributes" {
    const contact = try Contact.parse("\"Streats\" <sip:streats@192.168.1.130:54216;ob>");
    try testing.expect(std.mem.eql(u8, contact.name.?, "Streats"));
    try testing.expect(contact.protocol == .sip);
    try testing.expect(std.mem.eql(u8, contact.user, "streats"));
    try testing.expect(std.mem.eql(u8, contact.host, "192.168.1.130"));
    try testing.expect(contact.port == 54216);
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
        if (protocol.len > max_protocol_length) return HeaderError.InvalidHeader;

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

        return HeaderError.InvalidHeader;
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
    rport: ?u16 = null,
    ttl: ?u32 = null,
    received: ?[]const u8 = null, //source ip of the request
    maddr: ?[]const u8 = null, //multicast address
    sent_by: ?[]const u8 = null, //sender address when using multicast

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
        var via_header = ViaHeader{
            .protocol = undefined,
            .address = undefined,
            .branch = undefined,
        };
        const header_value = getHeaderValue(header_text);
        var reader = SliceReader.init(header_value);

        const sip = reader.readWhile(isTransport);
        if (!mem.eql(u8, sip, "SIP")) return HeaderError.InvalidHeader;

        _ = reader.readUntil(isTransport);
        const version = reader.readWhile(isTransport);
        if (!mem.eql(u8, version, "2.0")) return HeaderError.InvalidHeader;

        _ = reader.readUntil(isTransport);
        const protocol = reader.readWhile(isTransport);
        if (!mem.eql(u8, protocol, "UDP")) return HeaderError.InvalidHeader;
        via_header.protocol = try TransportProtocol.fromString(protocol);

        const address_text = std.mem.trimLeft(u8, reader.rest(), " ");
        via_header.address = try Address.parse(address_text);

        //get attributes
        const magic_cookie = "z9hG4bK";
        via_header.branch = try getHeaderParameter(header_text, "branch") orelse return HeaderError.InvalidHeader;
        if (!std.mem.startsWith(u8, via_header.branch, magic_cookie)) return HeaderError.InvalidHeader;

        if (try getHeaderParameter(header_text, "rport")) |rport| {
            via_header.rport = try std.fmt.parseInt(u16, rport, 10);
        }

        if (try getHeaderParameter(header_text, "ttl")) |ttl| {
            via_header.ttl = try std.fmt.parseInt(u32, ttl, 10);
        }

        via_header.received = try getHeaderParameter(header_text, "received");
        via_header.maddr = try getHeaderParameter(header_text, "maddr");
        via_header.sent_by = try getHeaderParameter(header_text, "sent_by");

        return via_header;
    }

    pub fn encode(self: ViaHeader, writer: anytype) !void {
        try writer.print("SIP/2.0/{s} {s}:{d}", .{ self.protocol.toString(), self.address.host, self.address.port });
        try writer.print(";branch={s}", .{self.branch});
        if (self.rport) |rport| try writer.print(";rport={d}", .{rport});
        if (self.ttl) |ttl| try writer.print(";ttl={d}", .{ttl});
        if (self.received) |received| try writer.print(";received={s}", .{received});
        if (self.maddr) |maddr| try writer.print(";maddr={s}", .{maddr});
        if (self.sent_by) |sent_by| try writer.print(";sent-by={s}", .{sent_by});
        try writer.writeAll("\r\n");
    }
};

test "ViaHeader parses values into fields" {
    const header_text = "SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh";
    const via = try ViaHeader.parse(header_text);

    try testing.expect(via.protocol == .udp);
    try testing.expect(std.mem.eql(u8, via.address.host, "192.168.1.130"));
    try testing.expect(via.address.port == 54216);
    try testing.expect(std.mem.eql(u8, via.branch, "z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh"));
}

test "ViaHeader parses with whitespace" {
    const header_text = "SIP / 2.0 / UDP first.example.com:4000 ;ttl=16\n;maddr=224.2.0.1 ;branch=z9hG4bKa7c6a8dlze.1";
    const via = try ViaHeader.parse(header_text);

    try testing.expect(via.protocol == .udp);
    try testing.expect(std.mem.eql(u8, via.address.host, "first.example.com"));
    try testing.expect(via.address.port == 4000);
    try testing.expect(via.ttl == 16);
    try testing.expect(std.mem.eql(u8, via.maddr.?, "224.2.0.1"));
    try testing.expect(std.mem.eql(u8, via.branch, "z9hG4bKa7c6a8dlze.1"));
}

test "ViaHeader encodes fields to text" {
    const via = ViaHeader{
        .protocol = .udp,
        .address = .{ .host = "192.168.1.130", .port = 54216 },
        .branch = "z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh",
        .ttl = 999,
    };

    var response_builder = std.ArrayList(u8).init(testing.allocator);
    defer response_builder.deinit();
    const writer = response_builder.writer();

    try via.encode(writer);
    try testing.expect(mem.eql(u8, response_builder.items, "SIP/2.0/UDP 192.168.1.130:54216;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh;ttl=999\r\n"));
}

pub const FromHeader = struct {
    contact: Contact,
    tag: ?[]const u8,

    pub fn parse(header_text: []const u8) !FromHeader {
        const contact_text = getHeaderValue(header_text);

        return FromHeader{
            .contact = try Contact.parse(contact_text),
            .tag = try getHeaderParameter(header_text, "tag"),
        };
    }

    //<sip:user@example.com>;tag=server-tag
    pub fn encode(self: FromHeader, writer: anytype) !void {
        try self.contact.encode(writer);
        if (self.tag) |tag| try writer.print(";tag={s}", .{tag});
        try writer.writeAll("\r\n");
    }
};

pub const ToHeader = FromHeader;

pub const Sequence = struct {
    number: u32,
    method: Method,

    pub fn parse(header_text: []const u8) !Sequence {
        var iter = mem.tokenizeScalar(u8, header_text, ' ');

        const number_text = iter.next() orelse return HeaderError.InvalidHeader;
        const method_text = iter.next() orelse return HeaderError.InvalidHeader;

        return Sequence{
            .number = try std.fmt.parseInt(u32, number_text, 10),
            .method = try Method.fromString(method_text),
        };
    }

    // 1 REGISTER
    pub fn encode(self: Sequence, writer: anytype) !void {
        try writer.print("{d} {s}\r\n", .{ self.number, self.method.toString() });
    }
};

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
    content_type,

    pub fn fromString(field: []const u8) !Header {
        const max_field_length = 128;
        if (field.len > max_field_length) return HeaderError.InvalidHeader;

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
        if (std.mem.eql(u8, field_lower, "content-type")) return Header.content_type;

        debug.print("bad header {s}\n", .{field_lower});
        return HeaderError.InvalidHeader;
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
            .content_type => return "Content-Type",
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
        return HeaderError.InvalidMethod;
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
