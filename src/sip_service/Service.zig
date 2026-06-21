const std = @import("std");
const headers = @import("../sip/headers.zig");
const Registration = @import("Registration.zig");
const sip = @import("../sip/server.zig");
const Message = @import("../sip/Message.zig");
const Transaction = @import("Transaction.zig");
const TransactionState = Transaction.TransactionState;

const Service = @This();

pub const ServiceError = error{
    MaxForwardsExceeded,
    NotRegistered,
    RecipientNotFound,
};

gpa: std.mem.Allocator,
io: std.Io,
transactions: std.StringHashMap(Transaction),
registrations: std.StringHashMap(Registration),

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Service {
    return Service{
        .gpa = gpa,
        .io = io,
        .transactions = .init(gpa),
        .registrations = .init(gpa),
    };
}

pub fn deinit(service: *Service) void {
    // TODO free keys
    service.transactions.deinit();
    service.registrations.deinit();
}

pub fn start(service: *Service, listen_address: []const u8, listen_port: u16) !void {
    var server = try sip.startServer(service.gpa, service.io, listen_address, listen_port);
    defer server.close();

    // TODO i feel like server.next() should catch internally
    while (try server.next()) |message| {
        defer message.deinit();
        const branch = try message.branch(); // TODO the underlying key gets freed after the message is handled. memory bug

        if (service.transactions.get(branch)) |transaction| {
            std.debug.print("existing transaction {s}\n", .{branch});
            try service.handleMessage(transaction, message);
            continue;
        }

        switch (message.start_line) {
            .request => |request_line| {
                std.debug.print("new transaction {s}\n", .{branch});

                const transaction = Transaction{
                    .method = request_line.method,
                    .state = if (request_line.method == .invite) .proceeding else .trying,
                };

                try service.transactions.put(branch, transaction);
                try service.handleMessage(transaction, message);
            },
            .response => {
                std.debug.print("Unknown transaction response, ignoring {s}\n", .{branch});
            },
        }
    }
}

pub fn handleMessage(service: *Service, transaction: Transaction, message: Message) !void {
    const new_state = switch (transaction.method) {
        .register => try transaction.handleRegister(service, message),
        else => blk: {
            // TODO reply not implemented
            break :blk TransactionState.completed;
        },
    };

    // If the transaction is complete we can stop tracking it, otherwise update it
    const branch = try message.branch();
    if (new_state == .terminated) {
        _ = service.transactions.remove(branch);
    } else {
        try service.transactions.put(branch, .{
            .method = transaction.method,
            .state = new_state,
        });
    }
}
