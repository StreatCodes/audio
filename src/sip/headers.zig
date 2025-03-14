const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const response = @import("./response.zig");

pub const Header = struct {
    const HeaderParameters = std.array_hash_map.StringArrayHashMap([]const u8);

    value: []const u8,
    parameters: HeaderParameters,

    //TODO we should trim these values
    pub fn parse(allocator: mem.Allocator, header_text: []const u8) !Header {
        var header: Header = undefined;

        var tokens = mem.tokenizeScalar(u8, header_text, ';');
        header.value = tokens.next() orelse return response.SIPError.InvalidHeader;
        header.parameters = HeaderParameters.init(allocator);

        while (tokens.next()) |token| {
            var param_tokens = mem.splitScalar(u8, token, '=');
            const param_field = param_tokens.next() orelse return response.SIPError.InvalidHeader;
            const param_value = param_tokens.next();
            if (param_tokens.next() != null) return response.SIPError.InvalidHeader;

            try header.parameters.put(param_field, param_value orelse "");
        }

        return header;
    }

    pub fn encode(self: Header, writer: anytype) !void {
        try writer.writeAll(self.value);

        var iter = self.parameters.iterator();
        while (iter.next()) |param| {
            const field = param.key_ptr.*;
            const value = param.value_ptr.*;

            try writer.print(";{s}", .{field});

            if (value.len > 0) {
                try writer.print("={s}", .{value});
            }
        }
    }

    pub fn clone(self: Header) !Header {
        return Header{
            .value = self.value,
            .parameters = try self.parameters.clone(),
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

pub const MessageType = union(enum) {
    request,
    response,
};
