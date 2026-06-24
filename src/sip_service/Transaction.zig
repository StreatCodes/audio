const std = @import("std");
const Service = @import("Service.zig");
const Message = @import("../sip/Message.zig");
const headers = @import("../sip/headers.zig");

pub const TransactionState = enum {
    /// This state will only be set for non-invite transactions
    trying,
    proceeding,
    completed,
    /// This state will only be set for invite transactions
    confirmed,
};

const Transaction = @This();

method: headers.Method,
state: TransactionState,
stream: std.Io.net.Stream,

pub fn send(transaction: Transaction, allocator: std.mem.Allocator, io: std.Io, message: Message) !void {
    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var writer = transaction.stream.writer(io, buffer).interface;

    const data = try message.encode(allocator);
    defer allocator.free(data);

    try writer.writeAll(data);
    std.debug.print("Sent [{s}]\n", .{data});
}

// TODO Handle AUTH!!
// TODO this is very brittle at the moment
pub fn handleRegister(transaction: Transaction, service: *Service, message: Message) !TransactionState {
    const expires = message.expires orelse return Message.MessageError.BadRequest;
    const id = try message.toIdentity(service.gpa);
    defer service.gpa.free(id);

    //TODO handle expires = 0 (logout)

    if (try service.registrations.getPtr(id)) |tx| {
        defer tx.deinit();
        tx.value.registered_at = .now(service.io, .real);
        tx.value.expires = expires;
    } else {
        try service.registrations.put(id, .{
            .registered_at = .now(service.io, .real),
            .expires = expires,
        });
    }

    var response = try message.newResponse(service.gpa, service.io, .ok);
    defer response.deinit();
    const message_alloc = response.arena.allocator();

    response.expires = expires;
    response.contact = try message.contact.clone(message_alloc);

    //TODO make this more robust
    try response.via.items[0].setReceiveAddress(message_alloc, transaction.stream.socket.address);

    const allowed = [_]headers.Method{ .invite, .ack, .bye, .cancel, .options, .register };
    try response.allow.appendSlice(message_alloc, &allowed);

    try transaction.send(service.gpa, service.io, response);

    return .completed;
}
