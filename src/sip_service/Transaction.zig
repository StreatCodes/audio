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

pub fn handleRegister(transaction: Transaction, service: *Service, message: Message) !TransactionState {
    _ = transaction;
    _ = service;
    _ = message;

    return .proceeding; //TODO remove
}
