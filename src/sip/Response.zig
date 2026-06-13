// TODO
// Fill common response headers from a request
// pub fn initFromRequest(allocator: mem.Allocator, request: Request) !Response {
//     var response = init();

//     //TODO add some validation for call_id and out of order sequences
//     //These fields have consistent responses across all methods
//     for (request.via.items) |via| {
//         try response.via.append(allocator, via);
//     }
//     response.to = request.to;
//     response.to.?.tag = "server-tag"; //TODO we need to make sure this is always present, validate in parse or seperate function
//     response.from = request.from;
//     response.call_id = request.call_id;

//     return response;
// }
