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
    terminated,
};

const Transaction = @This();

method: headers.Method,
state: TransactionState,

// TODO Handle AUTH!!
pub fn handleRegister(transaction: Transaction, service: *Service, message: Message) !TransactionState {
    _ = transaction;
    const expires = message.expires orelse return Message.MessageError.BadRequest;
    const id = try message.toIdentity(service.gpa);

    //TODO handle expires = 0 (logout)

    if (service.registrations.getPtr(id)) |registration| {
        defer service.gpa.free(id);
        registration.registered_at = .now(service.io, .real);
        registration.expires = expires;

        //TODO send response
    } else {
        // TODO create registration
        // service.registrations.put(id, .{
        //     .connection = message
        // })

    }

    return .completed;
}
