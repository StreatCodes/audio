const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;
const SliceReader = @import("util/SliceReader.zig");
const MessageError = @import("Message.zig").MessageError;

pub const HeaderError = error{
    InvalidMethod,
    InvalidHeader,
    UnknownExtension,
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
fn getHeaderParameter(comptime T: type, header_text: []const u8, attribute_name: []const u8) !?T {
    if (attribute_name.len > 126) return HeaderError.InvalidHeader;
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, ";{s}", .{attribute_name});

    const _start = std.mem.indexOf(u8, header_text, needle) orelse return null;
    const start = _start + needle.len;

    var remainder = header_text[start..];
    if (std.mem.indexOfScalar(u8, remainder, ';')) |end| {
        remainder = remainder[0..end];
    }
    var trimmed = std.mem.trim(u8, remainder, " \n");

    // booleans don't include '='
    if (T == bool) {
        return trimmed.len == 0;
    }

    if (trimmed.len == 0) return null;
    trimmed = trimmed[1..]; // remove '='

    switch (T) {
        []const u8 => {
            return std.mem.trim(u8, trimmed, "\"");
        },
        u32, u16 => |t| {
            return try fmt.parseInt(t, trimmed, 10);
        },
        f32 => {
            return try fmt.parseFloat(f32, trimmed);
        },
        else => {
            @compileError("unsupported type: " ++ @typeName(T));
        },
    }
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

// Contact: "Matt" <sip:matt@127.0.0.1:50517;transport=TCP;ob>;reg-id=1;+sip.instance="<urn:uuid:00000000-0000-0000-0000-0000b88b7722>";expires=300;q=0.9;methods="INVITE,ACK,BYE,CANCEL,OPTIONS";+sip.audio;+sip.video
pub const ContactHeader = struct {
    contact: Contact,
    expires: ?u32 = null,
    reg_id: ?u32 = null,
    q: ?f32 = null,
    methods: ?[]const u8 = null, // TODO technically an array of methods
    sip_instance: ?[]const u8 = null,
    sip_audio: bool = false,
    sip_video: bool = false,

    pub fn clone(original: ContactHeader, gpa: std.mem.Allocator) !ContactHeader {
        var new = original;
        new.contact = try original.contact.clone(gpa);
        new.methods = try gpa.dupe(u8, original.methods);
        new.sip_instance = try gpa.dupe(u8, original.sip_instance);

        return new;
    }

    pub fn parse(header_text: []const u8) !ContactHeader {
        const header_value = getHeaderValue(header_text);
        var contact_header = ContactHeader{
            .contact = try Contact.parse(header_value),
        };

        if (try getHeaderParameter(u32, header_text, "expires")) |expires_text| {
            contact_header.expires = expires_text;
        }

        if (try getHeaderParameter(u32, header_text, "reg-id")) |reg_id| {
            contact_header.reg_id = reg_id;
        }

        if (try getHeaderParameter(f32, header_text, "q")) |q| {
            contact_header.q = q;
        }

        if (try getHeaderParameter([]const u8, header_text, "methods")) |methods| {
            contact_header.methods = methods;
        }

        if (try getHeaderParameter([]const u8, header_text, "+sip.instance")) |sip_instance| {
            contact_header.sip_instance = sip_instance;
        }

        if (try getHeaderParameter(bool, header_text, "+sip.audio") == true) {
            contact_header.sip_audio = true;
        }

        if (try getHeaderParameter(bool, header_text, "+sip.video") == true) {
            contact_header.sip_video = true;
        }

        return contact_header;
    }

    //"Streats" <sip:streats@192.168.1.130:54216>;expires=3000
    pub fn encode(self: ContactHeader, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
        try self.contact.encode(allocator, buffer);
        if (self.expires) |expires| try buffer.print(allocator, ";expires={d}", .{expires});
        if (self.reg_id) |reg_id| try buffer.print(allocator, ";reg-id={d}", .{reg_id});
        if (self.q) |q| try buffer.print(allocator, ";q={d}", .{q});
        if (self.methods) |methods| try buffer.print(allocator, ";methods=\"{s}\"", .{methods});
        if (self.sip_instance) |sip_instance| try buffer.print(allocator, ";+sip.instance=\"{s}\"", .{sip_instance});
        if (self.sip_audio) try buffer.print(allocator, ";+sip.audio", .{});
        if (self.sip_video) try buffer.print(allocator, ";+sip.video", .{});

        try buffer.appendSlice(allocator, "\r\n");
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

    pub fn clone(original: Contact, gpa: std.mem.Allocator) !Contact {
        var new = original;
        if (original.name) |name| new.name = try gpa.dupe(u8, name);
        new.user = try gpa.dupe(u8, original.user);
        new.host = try gpa.dupe(u8, original.host);

        return new;
    }

    fn addressEnd(char: u8) bool {
        return char == '>' or char == ';';
    }

    fn alphaCharacter(char: u8) bool {
        if (char >= 'a' and char <= 'z') return true;
        if (char >= 'A' and char <= 'Z') return true;
        return false;
    }

    /// Parses a contact in the following formats
    /// ["Streats" <sip:streats@192.168.1.130:54216;ob>]
    /// [<sip:streats@localhost>]
    /// [sip:streats@localhost]
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

        if (reader.peek()) |next_char| {
            if (!alphaCharacter(next_char)) {
                _ = reader.readUntilScalarExcluding('<');
            }
        }

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
    pub fn encode(self: Contact, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
        if (self.name) |name| try buffer.print(allocator, "\"{s}\" ", .{name});
        try buffer.print(allocator, "<{s}:{s}@{s}", .{ self.protocol.toString(), self.user, self.host });
        if (self.port) |port| {
            //TODO convert to switch when we have other protocols
            if (self.protocol == .sip and self.port != 5060) {
                try buffer.print(allocator, ":{d}", .{port});
            }
        }
        if (self.ob) {
            try buffer.appendSlice(allocator, ";ob");
        }
        _ = try buffer.append(allocator, '>');
    }
};

test "Contact can parse with no name or angled brackets" {
    const contact = try Contact.parse("sip:streats@localhost");
    try testing.expectEqual(contact.name, null);
    try testing.expectEqual(contact.protocol, .sip);
    try testing.expectEqualStrings(contact.user, "streats");
    try testing.expectEqualStrings(contact.host, "localhost");
    try testing.expectEqual(contact.port, 5060);
}

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

//TODO use above in Contact
pub const Address = struct {
    host: []const u8,
    port: u16,

    pub fn clone(original: Address, gpa: std.mem.Allocator) !Address {
        var new = original;
        new.host = try gpa.dupe(u8, original.host);

        return new;
    }

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

    pub fn clone(original: ViaHeader, gpa: std.mem.Allocator) !ViaHeader {
        var new = original;
        new.address = try original.address.clone(gpa);
        new.branch = try gpa.dupe(u8, original.branch);
        if (original.received) |received| new.received = try gpa.dupe(u8, received);
        if (original.maddr) |maddr| new.maddr = try gpa.dupe(u8, maddr);
        if (original.sent_by) |sent_by| new.sent_by = try gpa.dupe(u8, sent_by);

        return new;
    }

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
        if (!mem.eql(u8, protocol, "UDP") and !mem.eql(u8, protocol, "TCP")) return HeaderError.InvalidHeader;
        via_header.protocol = try TransportProtocol.fromString(protocol);

        const address_text = std.mem.trimStart(u8, reader.rest(), " ");
        via_header.address = try Address.parse(address_text);

        //get attributes
        const magic_cookie = "z9hG4bK";
        via_header.branch = try getHeaderParameter([]const u8, header_text, "branch") orelse return HeaderError.InvalidHeader;
        if (!std.mem.startsWith(u8, via_header.branch, magic_cookie)) return HeaderError.InvalidHeader;

        if (try getHeaderParameter(u16, header_text, "rport")) |rport| {
            via_header.rport = rport;
        }

        if (try getHeaderParameter(u32, header_text, "ttl")) |ttl| {
            via_header.ttl = ttl;
        }

        via_header.received = try getHeaderParameter([]const u8, header_text, "received");
        via_header.maddr = try getHeaderParameter([]const u8, header_text, "maddr");
        via_header.sent_by = try getHeaderParameter([]const u8, header_text, "sent_by");

        return via_header;
    }

    pub fn encode(self: ViaHeader, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
        try buffer.print(allocator, "SIP/2.0/{s} {s}:{d}", .{ self.protocol.toString(), self.address.host, self.address.port });
        try buffer.print(allocator, ";branch={s}", .{self.branch});
        if (self.rport) |rport| try buffer.print(allocator, ";rport={d}", .{rport});
        if (self.ttl) |ttl| try buffer.print(allocator, ";ttl={d}", .{ttl});
        if (self.received) |received| try buffer.print(allocator, ";received={s}", .{received});
        if (self.maddr) |maddr| try buffer.print(allocator, ";maddr={s}", .{maddr});
        if (self.sent_by) |sent_by| try buffer.print(allocator, ";sent-by={s}", .{sent_by});
        try buffer.appendSlice(allocator, "\r\n");
    }

    pub fn setReceiveAddress(self: *ViaHeader, allocator: std.mem.Allocator, net_address: std.Io.net.IpAddress) !void {
        switch (net_address) {
            .ip4 => |addr| {
                const host = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                    addr.bytes[0],
                    addr.bytes[1],
                    addr.bytes[2],
                    addr.bytes[3],
                });

                self.received = host;
                self.rport = addr.port;
            },
            .ip6 => |addr| {
                _ = addr;
                @panic("TODO");
            },
        }
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

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(std.testing.allocator);

    try via.encode(std.testing.allocator, &response);
    try testing.expectEqualStrings(response.items, "SIP/2.0/UDP 192.168.1.130:54216;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh;ttl=999\r\n");
}

pub const FromHeader = struct {
    contact: Contact,
    tag: ?[]const u8,

    pub fn clone(original: FromHeader, gpa: std.mem.Allocator) !FromHeader {
        var new = original;
        new.contact = try original.contact.clone(gpa);
        if (original.tag) |tag| new.tag = try gpa.dupe(u8, tag);

        return new;
    }

    pub fn parse(header_text: []const u8) !FromHeader {
        const contact_text = getHeaderValue(header_text);

        return FromHeader{
            .contact = try Contact.parse(contact_text),
            .tag = try getHeaderParameter([]const u8, header_text, "tag"),
        };
    }

    //<sip:user@example.com>;tag=server-tag
    pub fn encode(self: FromHeader, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
        try self.contact.encode(allocator, buffer);
        if (self.tag) |tag| try buffer.print(allocator, ";tag={s}", .{tag});
        try buffer.appendSlice(allocator, "\r\n");
    }

    /// Generates a cryptographically random tag on the header
    pub fn generateTag(self: *FromHeader, allocator: std.mem.Allocator, io: std.Io) !void {
        var buffer: [20]u8 = undefined;
        try std.Io.randomSecure(io, &buffer);

        self.tag = try std.fmt.allocPrint(allocator, "{x}", .{buffer});
    }
};

pub const RecordRoute = struct {
    address: Address,
    lr: bool,

    pub fn clone(original: RecordRoute, gpa: std.mem.Allocator) !RecordRoute {
        var new = original;
        new.address = try original.address.clone(gpa);

        return new;
    }

    pub fn parse(raw_header_text: []const u8) !RecordRoute {
        var header_text = raw_header_text;
        if (mem.startsWith(u8, raw_header_text, "<")) {
            header_text = raw_header_text[1 .. raw_header_text.len - 1];
        }
        if (mem.startsWith(u8, header_text, "sip:")) {
            header_text = header_text[4..];
        }
        const uri = getHeaderValue(header_text);
        const lr = try getHeaderParameter(bool, header_text, "lr") == true;

        return RecordRoute{
            .address = try Address.parse(uri),
            .lr = lr,
        };
    }

    // <sip:server.example.com;lr>
    pub fn encode(self: RecordRoute, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
        try buffer.print(allocator, "<sip:{s}:{d}", .{ self.address.host, self.address.port });
        if (self.lr) {
            try buffer.appendSlice(allocator, ";lr");
        }
        try buffer.appendSlice(allocator, ">\r\n");
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
    pub fn encode(self: Sequence, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
        try buffer.print(allocator, "{d} {s}\r\n", .{ self.number, self.method.toString() });
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
    record_route,
    contact,
    expires,
    allow,
    content_length,
    content_type,
    supported,
    accept,

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
        if (std.mem.eql(u8, field_lower, "record-route")) return Header.record_route;
        if (std.mem.eql(u8, field_lower, "contact")) return Header.contact;
        if (std.mem.eql(u8, field_lower, "expires")) return Header.expires;
        if (std.mem.eql(u8, field_lower, "allow")) return Header.allow;
        if (std.mem.eql(u8, field_lower, "content-length")) return Header.content_length;
        if (std.mem.eql(u8, field_lower, "content-type")) return Header.content_type;
        if (std.mem.eql(u8, field_lower, "supported")) return Header.supported;
        if (std.mem.eql(u8, field_lower, "accept")) return Header.accept;

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
            .record_route => return "Record-Route",
            .contact => return "Contact",
            .expires => return "Expires",
            .allow => return "Allow",
            .content_length => return "Content-Length",
            .content_type => return "Content-Type",
            .supported => return "Supported",
            .accept => return "Accept",
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

pub const Extension = enum {
    replaces,
    one_hundred_rel,
    no_refer_sub,
    timer,
    outbound,
    path,

    pub fn fromString(extension: []const u8) !Extension {
        if (std.mem.eql(u8, extension, "replaces")) return Extension.replaces;
        if (std.mem.eql(u8, extension, "100rel")) return Extension.one_hundred_rel;
        if (std.mem.eql(u8, extension, "norefersub")) return Extension.no_refer_sub;
        if (std.mem.eql(u8, extension, "timer")) return Extension.timer;
        if (std.mem.eql(u8, extension, "outbound")) return Extension.outbound;
        if (std.mem.eql(u8, extension, "path")) return Extension.path;
        debug.print("unknown extension: {s}\n", .{extension});
        return HeaderError.UnknownExtension;
    }

    pub fn toString(self: Extension) []const u8 {
        switch (self) {
            .replaces => return "replaces",
            .one_hundred_rel => return "100rel",
            .no_refer_sub => return "norefersub",
            .timer => return "timer",
            .outbound => return "outbound",
            .path => return "path",
        }
    }
};

pub const StartLine = union(enum) {
    request: RequestLine,
    response: ResponseLine,

    pub fn clone(original: StartLine, gpa: std.mem.Allocator) !StartLine {
        switch (original) {
            .request => |req| return .{ .request = try req.clone(gpa) },
            .response => |res| return .{ .response = try res.clone(gpa) },
        }
    }

    pub fn parse(line: []const u8) !StartLine {
        if (std.mem.startsWith(u8, line, "SIP/2.0")) {
            return .{ .response = try ResponseLine.parse(line) };
        }
        return .{ .request = try RequestLine.parse(line) };
    }

    pub fn encode(start_line: StartLine, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
        switch (start_line) {
            .request => |req| {
                try buffer.print(allocator, "{s} {f} SIP/2.0\r\n", .{ req.method.toString(), req.uri });
            },
            .response => |res| {
                try buffer.print(allocator, "SIP/2.0 {d} {s}\r\n", .{ @intFromEnum(res.status), res.status.toString() });
            },
        }
    }
};

pub const RequestLine = struct {
    method: Method,
    uri: std.Uri,
    version: []const u8,

    //TODO .uri is not copied, not even sure how to.
    pub fn clone(original: RequestLine, gpa: std.mem.Allocator) !RequestLine {
        var new = original;
        new.version = try gpa.dupe(u8, original.version);

        return new;
    }

    pub fn parse(line: []const u8) !RequestLine {
        var parts = std.mem.splitScalar(u8, line, ' ');

        const method = parts.next() orelse return MessageError.BadRequest;
        const uri = parts.next() orelse return MessageError.BadRequest;
        const version = parts.next() orelse return MessageError.BadRequest;

        return .{
            .method = try Method.fromString(method),
            .uri = try std.Uri.parse(uri),
            .version = version,
        };
    }
};

pub const ResponseLine = struct {
    version: []const u8,
    status: StatusCode,

    pub fn clone(original: ResponseLine, gpa: std.mem.Allocator) !ResponseLine {
        var new = original;
        new.version = try gpa.dupe(u8, original.version);

        return new;
    }

    pub fn parse(line: []const u8) !ResponseLine {
        var parts = std.mem.splitScalar(u8, line, ' ');

        const version = parts.next() orelse return MessageError.BadResponse;
        const status_text = parts.next() orelse return MessageError.BadResponse;

        if (!std.mem.eql(u8, version, "SIP/2.0")) return MessageError.BadResponse;
        const status = try fmt.parseInt(u32, status_text, 10);

        return .{
            .version = version,
            .status = StatusCode.fromCode(status),
        };
    }
};

pub const StatusCode = enum(u32) {
    trying = 100,
    ringing = 180,
    ok = 200,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    internal_error = 500,
    not_implemented = 501,
    decline = 603,
    _,

    pub fn toString(self: StatusCode) []const u8 {
        switch (self) {
            .trying => return "Trying",
            .ok => return "OK",
            .ringing => return "Ringing",
            .bad_request => return "Bad Request",
            .unauthorized => return "Unauthorized",
            .forbidden => return "Forbidden",
            .not_found => return "Not Found",
            .internal_error => return "Server Internal Error",
            .not_implemented => return "Not Implemented",
            .decline => return "Decline",
            else => return "Unknown",
        }
    }

    pub fn fromCode(code: u32) StatusCode {
        return @enumFromInt(code);
    }
};

test "Generate tag populates the tag on a To/From header" {
    var from = FromHeader{
        .contact = .{
            .host = "localhost",
            .user = "mort",
            .protocol = .sip,
        },
        .tag = null,
    };

    try from.generateTag(testing.allocator, testing.io);
    defer testing.allocator.free(from.tag.?);

    try testing.expectEqual(from.tag.?.len, 40);
}

test "Contact header parses and encodes all standardised paramaters" {
    const header_text = "\"Matt\" <sip:matt@127.0.0.1:50517>;" ++
        "reg-id=1;+sip.instance=\"<urn:uuid:00000000-0000-0000-0000-0000b88b7722>\";expires=300;q=0.9;" ++
        "methods=\"INVITE,ACK,BYE,CANCEL,OPTIONS\";+sip.audio;+sip.video";

    const contact_header = try ContactHeader.parse(header_text);
    try testing.expectEqual(1, contact_header.reg_id.?);
    try testing.expectEqualStrings("<urn:uuid:00000000-0000-0000-0000-0000b88b7722>", contact_header.sip_instance.?);
    try testing.expectEqual(300, contact_header.expires.?);
    try testing.expectEqual(0.9, contact_header.q.?);
    try testing.expectEqualStrings("INVITE,ACK,BYE,CANCEL,OPTIONS", contact_header.methods.?);
    try testing.expectEqual(true, contact_header.sip_audio);
    try testing.expectEqual(true, contact_header.sip_video);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try contact_header.encode(testing.allocator, &buffer);
    const encoded = buffer.items;

    const expected_text = "\"Matt\" <sip:matt@127.0.0.1:50517>;" ++
        "expires=300;reg-id=1;q=0.9;methods=\"INVITE,ACK,BYE,CANCEL,OPTIONS\";" ++
        "+sip.instance=\"<urn:uuid:00000000-0000-0000-0000-0000b88b7722>\";+sip.audio;+sip.video\r\n";

    try testing.expectEqualStrings(expected_text, encoded);
}
