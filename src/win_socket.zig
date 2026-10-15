//! Socket readiness on Windows. std.Io's sockets there are AFD endpoint handles, which WSAPoll does
//! not accept, so readiness is asked of AFD itself (IOCTL_AFD_POLL, the request libuv and wepoll use).
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const RECEIVE: u32 = 0x1;
pub const DISCONNECT: u32 = 0x8;
pub const ABORT: u32 = 0x10;
pub const LOCAL_CLOSE: u32 = 0x20;
pub const ACCEPT: u32 = 0x80;
/// The peer is gone: a FIN, a reset, or our own close.
pub const GONE: u32 = DISCONNECT | ABORT | LOCAL_CLOSE;

const HandleInfo = extern struct { handle: windows.HANDLE, events: u32, status: windows.NTSTATUS };
const PollInfo = extern struct { timeout: i64, number_of_handles: u32, exclusive: u32, handles: [1]HandleInfo };

extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: i32, initial_state: i32, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, ms: u32) callconv(.winapi) u32;

/// The subset of `events` that holds for `handle` within `timeout_ms` (0 probes); 0 on timeout.
pub fn poll(handle: windows.HANDLE, events: u32, timeout_ms: i32) error{PollFailed}!u32 {
    var info = PollInfo{
        .timeout = -@as(i64, @max(timeout_ms, 0)) * 10_000, // relative, in 100 ns units
        .number_of_handles = 1,
        .exclusive = 0,
        .handles = .{.{ .handle = handle, .events = events, .status = .SUCCESS }},
    };
    const event = CreateEventW(null, 1, 0, null) orelse return error.PollFailed;
    defer windows.CloseHandle(event);
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var status = windows.ntdll.NtDeviceIoControlFile(handle, event, null, null, &iosb, windows.IOCTL.AFD.POLL, &info, @sizeOf(PollInfo), &info, @sizeOf(PollInfo));
    if (status == .PENDING) {
        _ = WaitForSingleObject(event, 0xFFFFFFFF);
        status = iosb.u.Status;
    }
    if (status == .TIMEOUT) return 0; // AFD's timeout is a status, not an empty success
    if (status != .SUCCESS) return error.PollFailed;
    return if (info.number_of_handles == 0) 0 else info.handles[0].events & events;
}

test "win_socket: a listener times out with no client, then reports the connection to accept" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    try std.testing.expectEqual(@as(u32, 0), try poll(server.socket.handle, ACCEPT, 50));

    var client = try server.socket.address.connect(io, .{ .mode = .stream });
    try std.testing.expect(try poll(server.socket.handle, ACCEPT, 2000) & ACCEPT != 0);

    var conn = try server.accept(io);
    defer conn.close(io);
    try std.testing.expectEqual(@as(u32, 0), try poll(conn.socket.handle, RECEIVE | GONE, 0));
    client.close(io);
    try std.testing.expect(try poll(conn.socket.handle, GONE, 2000) & GONE != 0);
}
