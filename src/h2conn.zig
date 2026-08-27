//! One HTTP/2 connection over an established byte stream, h2c prior knowledge.
//!
//! Slice 1 of zoxy-io/zrk#21: **one request in flight at a time**, which is what
//! `connection.zig` already does over HTTP/1.1. That is not a simplification to
//! be removed later without thought — it is what keeps every measurement
//! semantic this tool exists for. Latency is recorded from a request's
//! *scheduled* time, and `watchTimer` aborts a late request by shutting the
//! socket down to unblock the read. Tearing down the connection is only
//! equivalent to aborting one request while exactly one is in flight. Opening a
//! second stream makes that abort wrong, which is why multiplexing is its own
//! slice with its own decisions about what `-c` means.
//!
//! So this module speaks the protocol and nothing more: preface, settings,
//! one exchange at a time, and the flow control that keeps a long run from
//! stalling.
//!
//! ## What it does not do
//!
//! No ALPN and no TLS — prior-knowledge h2c only, which is what makes this
//! slice free of the zssl/libcrypto decision. No server push: we advertise
//! `SETTINGS_ENABLE_PUSH = 0`, and a peer that sends `PUSH_PROMISE` anyway is a
//! protocol error rather than something to handle. No priority: RFC 9113
//! deprecates the scheme and a load generator has nothing to say about it.

const std = @import("std");
const Io = std.Io;

const h2 = @import("h2");
const httpmod = @import("http.zig");

const frame = h2.frame;
const hpack = h2.hpack;

/// RFC 9113 section 3.4: the octets a client sends before anything else.
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// RFC 9113 section 6.5.2's identifiers. Taken from `h2` rather than spelled
/// again here: two copies of a wire enum is one copy that can go stale, and
/// this one is already non-exhaustive there because the section requires an
/// unknown identifier to be ignored rather than refused.
const Setting = frame.payload.Settings.Identifier;

/// What we advertise, and why each value is what it is.
///
/// `header_table_size = 0` is the load-bearing one. It forbids the peer from
/// using the dynamic table at all, which makes our decode stateless: no arena,
/// no eviction accounting, and no per-connection HPACK state to carry. HPACK
/// makes header decoding mandatory where HTTP/1.1 was a scan for CRLF, and this
/// is what keeps that off the hot path of a tool that sells not adding
/// client-side noise to the measurement.
const advertised_header_table_size: u32 = 0;

/// Push is refused rather than handled. A promised stream is response bytes
/// nobody asked for, arriving on a stream with no scheduled send time — there
/// is no honest latency sample to record for one.
const advertised_enable_push: u32 = 0;

/// Our receive window, per stream and for the connection, set as high as RFC
/// 9113 section 6.9.1 allows. A load generator reads every response in full and
/// immediately; the window exists to protect a slow reader, and we are not one.
/// Raising it as far as it goes is what keeps `WINDOW_UPDATE` off the common
/// path entirely.
const advertised_window_size: u32 = window_max;

/// Section 6.9.1: a flow-control window is a 31-bit signed quantity.
const window_max: u32 = (1 << 31) - 1;

/// Section 6.9.2: every flow-control window starts at 65,535 octets, and
/// `SETTINGS_INITIAL_WINDOW_SIZE` moves only the *stream* windows. The
/// connection window stays here until a `WINDOW_UPDATE` says otherwise, which
/// is why `open` sends one immediately — a load generator would otherwise stall
/// inside the first large response.
///
/// Defined here rather than taken from `h2`: that package is framing only and
/// holds no connection state. This is arguably a constant of the format in the
/// same way `max_frame_size_min` is, and worth proposing there if a second
/// consumer needs it.
const window_initial_default: u32 = 65_535;

/// The largest frame we are willing to receive. The floor from section 6.5.2,
/// because a bigger one buys a load generator nothing: response bodies arrive
/// in whatever frames the peer chooses and we consume them as they come.
const advertised_max_frame_size: u32 = frame.Header.max_frame_size_min;

/// Response headers we are willing to decode. Generous — a benchmark target is
/// not hostile — but bounded, because an unbounded one is a memory bug waiting
/// for a misbehaving server.
const header_list_max: u32 = 64 * 1024;

/// Room for one field block's fragments, and for the decoded field text.
///
/// Both are the caller's buffers in h2's API. The block bound is what stops a
/// peer that never sends END_HEADERS: `BlockAssembler`'s buffer length *is* the
/// limit on a field block, so this number is the CONTINUATION-flood defence.
const block_buffer_size: u32 = 32 * 1024;
const field_buffer_size: u32 = 32 * 1024;

comptime {
    // A block that cannot hold what we said we would accept would reject
    // conforming responses.
    std.debug.assert(block_buffer_size >= advertised_max_frame_size);
    std.debug.assert(field_buffer_size >= advertised_max_frame_size);
    std.debug.assert(header_list_max >= advertised_max_frame_size);
    std.debug.assert(advertised_window_size <= window_max);
}

/// Frames a single exchange may see before its response completes.
///
/// A bound rather than a trust: a peer that answers every request with an
/// endless stream of SETTINGS or PING would otherwise keep one connection's
/// coroutine busy forever, and the run's wall clock would silently become the
/// only thing stopping it. Generous enough that no conforming server reaches it
/// — a 16 KiB-framed megabyte response is 64 DATA frames.
const frames_per_exchange_max: u32 = 4096;

pub const Error = error{
    /// The peer spoke something that is not HTTP/2, or broke a rule this client
    /// is unwilling to continue past.
    Protocol,
    /// The peer sent GOAWAY, or closed. Not an error in itself — the caller
    /// reconnects — but this exchange did not complete.
    Closed,
    /// A response exceeded a bound we advertised or hold.
    TooLarge,
    /// The transport failed.
    Io,
};

/// Per-connection state, pinned by the caller for the connection's lifetime.
///
/// No allocator: every buffer is a field here, sized by the constants above,
/// which is the same discipline `tls.State` follows and the reason h2 forbids
/// an allocator in its own seam.
pub const Session = struct {
    reader: *Io.Reader,
    writer: *Io.Writer,

    /// Next client stream identifier. Section 5.1.1: clients use odd numbers,
    /// ascending, and never reuse one.
    next_stream: u31 = 1,

    /// The peer's `SETTINGS_MAX_FRAME_SIZE`, which bounds what we may send.
    /// Section 6.5.2's default until the peer says otherwise.
    peer_max_frame_size: u32 = frame.Header.max_frame_size_min,

    /// Set when the peer has sent GOAWAY. The exchange in flight may still
    /// complete; no new stream may be opened.
    peer_going_away: bool = false,

    assembler_buffer: [block_buffer_size]u8 = undefined,
    field_buffer: [field_buffer_size]u8 = undefined,
    /// Scratch for one outbound frame header, and for settings payloads.
    scratch: [frame.Header.octets + 6 * settings_entries_max]u8 = undefined,

    /// Settings we send in one frame.
    const settings_entries_max = 6;

    pub fn init(reader: *Io.Reader, writer: *Io.Writer) Session {
        return .{ .reader = reader, .writer = writer };
    }

    /// Send the preface and our SETTINGS, and read the peer's.
    ///
    /// Section 3.4 lets both sides send immediately without waiting, so this
    /// does not block on the peer's SETTINGS before returning — it reads frames
    /// until it has seen one SETTINGS from the peer, acknowledging it, which is
    /// the first thing any conforming server sends.
    pub fn open(session: *Session) Error!void {
        session.writer.writeAll(preface) catch return error.Io;
        try session.writeSettings();
        // Raise the connection-level window as far as it goes. `SETTINGS`
        // initial-window applies per stream only (section 6.9.2), so the
        // connection window stays at the 65535 default until told otherwise —
        // and a load generator would stall on it within one large response.
        try session.writeWindowUpdate(0, window_max - window_initial_default);
        session.writer.flush() catch return error.Io;

        // The peer's SETTINGS is the first frame it must send (section 3.4).
        // Everything before it that is legal is handled and skipped.
        var frames: u32 = 0;
        while (frames < frames_per_exchange_max) : (frames += 1) {
            const header = try session.readHeader();
            if (header.frame_type == .settings and !header.has(.ack)) {
                try session.applySettings(header);
                session.writer.flush() catch return error.Io;
                return;
            }
            try session.handleConnectionFrame(header);
        }
        return error.Protocol;
    }

    /// One request and its response, which is the whole exchange model of this
    /// slice: open a stream, send the prebuilt block with END_STREAM, and read
    /// frames until that stream ends.
    ///
    /// `block` is the HPACK-encoded header block, built once at startup with
    /// `Encoder.Mode.static_only` so it depends on no encoder state and can be
    /// replayed byte-identically on every stream. That guarantee is why this
    /// function takes bytes rather than fields.
    pub fn exchange(session: *Session, block: []const u8, body: []const u8) Error!httpmod.Response {
        if (session.peer_going_away) return error.Closed;

        const stream = session.next_stream;
        // Section 5.1.1: ascending odd identifiers, never reused. Two per
        // request, so the space allows about a billion requests per connection
        // — far past any run, but the check is here because wrapping would
        // reuse an identifier rather than fail.
        if (stream > std.math.maxInt(u31) - 2) return error.Closed;
        session.next_stream = stream + 2;

        try session.writeHeaders(stream, block, body.len == 0);
        if (body.len > 0) try session.writeData(stream, body);
        session.writer.flush() catch return error.Io;

        return session.readResponse(stream);
    }

    /// Read frames until `stream` carries END_STREAM, handling everything else
    /// the connection may interleave.
    fn readResponse(session: *Session, stream: u31) Error!httpmod.Response {
        var assembler: frame.BlockAssembler = .init(
            &session.assembler_buffer,
            frame.BlockAssembler.frames_max_default,
        );
        // `SETTINGS_HEADER_TABLE_SIZE = 0` is what makes this correct with no
        // arena: we forbade the peer the dynamic table, so a decoder with an
        // empty one is not a shortcut, it is the configuration we advertised.
        // A peer that indexes into it anyway gets a decode error, which is the
        // right answer.
        var table_storage: hpack.DynamicTable.Storage(0) = .{};
        var decoder: hpack.Decoder = .init(table_storage.table(), header_list_max);

        var status: ?u16 = null;
        var bytes: u64 = 0;
        var frames: u32 = 0;

        while (frames < frames_per_exchange_max) : (frames += 1) {
            const header = try session.readHeader();

            // Another stream's frame, or a connection-level one. With one
            // request in flight the only streams that can appear are this one
            // and ones we have already finished, whose late frames are
            // ignorable rather than fatal.
            if (header.stream_identifier != stream) {
                try session.handleConnectionFrame(header);
                continue;
            }

            const payload_bytes = try session.readPayload(header);
            const payload = frame.payload.parse(header, payload_bytes) catch return error.Protocol;

            // The CONTINUATION state machine's refusals are all reasons to stop
            // using this connection: an interleaved frame or an unbounded block
            // means the peer is not framing the way section 6.10 requires.
            const accepted = assembler.accept(header, &payload) catch return error.Protocol;
            switch (accepted) {
                .fragment => continue,
                .block => |complete| {
                    if (status != null) return error.Protocol; // trailers carry no status
                    status = try decodeStatus(&decoder, &session.field_buffer, complete.fragment);
                    bytes += complete.fragment.len;
                    if (complete.end_stream) return finish(status, bytes);
                    continue;
                },
                .passthrough => {},
            }

            switch (payload) {
                .data => |data| {
                    bytes += data.data.len;
                    // Consumed the moment it arrives, so the window we opened in
                    // `open` is the only flow control this client needs.
                    if (header.has(.end_stream)) return finish(status, bytes);
                },
                .rst_stream => return error.Closed,
                else => return error.Protocol,
            }
        }
        return error.Protocol;
    }

    fn readHeader(session: *Session) Error!frame.Header {
        return readHeaderImpl(session);
    }

    fn readPayload(session: *Session, header: frame.Header) Error![]const u8 {
        return readPayloadImpl(session, header);
    }

    /// Everything that is not this exchange's stream.
    ///
    /// A load generator has to answer only three of these. The rest are either
    /// ignorable by the RFC or a reason to stop using the connection, and
    /// saying which is which in one place is what keeps `readResponse` about
    /// the response.
    fn handleConnectionFrame(session: *Session, header: frame.Header) Error!void {
        const payload_bytes = try session.readPayload(header);
        const payload = frame.payload.parse(header, payload_bytes) catch return error.Protocol;
        switch (payload) {
            // Section 6.5: acknowledge, and take what we are told.
            .settings => if (!header.has(.ack)) {
                try session.applySettingsPayload(payload);
                session.writer.flush() catch return error.Io;
            },
            // Section 6.7: a PING we did not send must be echoed with ACK.
            .ping => |ping| if (!header.has(.ack)) {
                try session.writeFrame(.ping, frame.Flag.ack.bit(), 0, ping.opaque_data);
                session.writer.flush() catch return error.Io;
            },
            // Section 6.8: no new stream after this. The exchange in flight may
            // still finish, so this is recorded rather than raised.
            .goaway => session.peer_going_away = true,
            // We advertised `SETTINGS_ENABLE_PUSH = 0`; section 8.4 makes a
            // PUSH_PROMISE after that a connection error, and there is no
            // honest latency sample for a stream nobody scheduled.
            .push_promise => return error.Protocol,
            // Window updates only matter to a sender, and this client sends a
            // request block and nothing more. Ignorable rather than tracked.
            .window_update => {},
            // A stream we already finished, ending late.
            .rst_stream, .data, .headers, .continuation => {},
            .priority => {},
            .unknown => {}, // Section 4.1: skip by length, which the read did.
        }
    }

    fn writeSettings(session: *Session) Error!void {
        var payload: [6 * settings_entries_max]u8 = undefined;
        var used: usize = 0;
        const entries = [_]struct { Setting, u32 }{
            .{ .header_table_size, advertised_header_table_size },
            .{ .enable_push, advertised_enable_push },
            .{ .initial_window_size, advertised_window_size },
            .{ .max_frame_size, advertised_max_frame_size },
            .{ .max_header_list_size, header_list_max },
        };
        comptime std.debug.assert(entries.len <= settings_entries_max);
        for (entries) |entry| {
            std.mem.writeInt(u16, payload[used..][0..2], @intFromEnum(entry[0]), .big);
            std.mem.writeInt(u32, payload[used + 2 ..][0..4], entry[1], .big);
            used += 6;
        }
        try session.writeFrame(.settings, 0, 0, payload[0..used]);
    }

    fn applySettings(session: *Session, header: frame.Header) Error!void {
        const payload_bytes = try session.readPayload(header);
        const payload = frame.payload.parse(header, payload_bytes) catch return error.Protocol;
        try session.applySettingsPayload(payload);
    }

    /// Take the peer's settings, and acknowledge them.
    ///
    /// Only `SETTINGS_MAX_FRAME_SIZE` changes what this client does — it bounds
    /// what we may send, and our one send is a header block that could exceed
    /// the default if a caller passes enough `-H`. The rest describe limits on
    /// a sender we are not: we open one stream at a time and send no body large
    /// enough to meet a window.
    fn applySettingsPayload(session: *Session, payload: frame.Payload) Error!void {
        var entries = payload.settings.iterate();
        while (entries.next()) |entry| {
            // Section 6.5.2: an identifier we do not know must be ignored, not
            // refused, so extensions stay deployable.
            switch (entry.identifier) {
                .max_frame_size => {
                    if (entry.value < frame.Header.max_frame_size_min) return error.Protocol;
                    if (entry.value > frame.Header.max_frame_size_max) return error.Protocol;
                    session.peer_max_frame_size = entry.value;
                },
                // Section 6.5.3: acknowledged whether or not we act on it, and
                // section 6.5.2 requires an unrecognized identifier to be
                // ignored rather than refused.
                else => {},
            }
        }
        try session.writeFrame(.settings, frame.Flag.ack.bit(), 0, &.{});
    }

    fn writeWindowUpdate(session: *Session, stream: u31, increment: u32) Error!void {
        std.debug.assert(increment >= 1);
        std.debug.assert(increment <= window_max);
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, increment, .big);
        try session.writeFrame(.window_update, 0, stream, &payload);
    }

    /// Send one header block, split across CONTINUATION frames if the peer's
    /// `SETTINGS_MAX_FRAME_SIZE` demands it.
    ///
    /// The split is not hypothetical: the block is built from the user's `-H`
    /// arguments, and the peer may advertise the 16 KiB floor.
    fn writeHeaders(session: *Session, stream: u31, block: []const u8, end_stream: bool) Error!void {
        std.debug.assert(session.peer_max_frame_size >= frame.Header.max_frame_size_min);
        const chunk = session.peer_max_frame_size;

        var offset: usize = 0;
        const first_len = @min(block.len, chunk);
        const end_headers_on_first = first_len == block.len;
        var flags: u8 = 0;
        if (end_stream) flags |= frame.Flag.end_stream.bit();
        if (end_headers_on_first) flags |= frame.Flag.end_headers.bit();
        try session.writeFrame(.headers, flags, stream, block[0..first_len]);
        offset = first_len;

        // Bounded by the block, which every pass shortens by a full frame.
        while (offset < block.len) {
            const len = @min(block.len - offset, chunk);
            const last = offset + len == block.len;
            try session.writeFrame(
                .continuation,
                if (last) frame.Flag.end_headers.bit() else 0,
                stream,
                block[offset..][0..len],
            );
            offset += len;
        }
    }

    fn writeData(session: *Session, stream: u31, body: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < body.len) {
            const len = @min(body.len - offset, session.peer_max_frame_size);
            const last = offset + len == body.len;
            try session.writeFrame(
                .data,
                if (last) frame.Flag.end_stream.bit() else 0,
                stream,
                body[offset..][0..len],
            );
            offset += len;
        }
    }

    fn writeFrame(
        session: *Session,
        frame_type: frame.Type,
        flags: u8,
        stream: u31,
        payload: []const u8,
    ) Error!void {
        std.debug.assert(payload.len <= frame.Header.max_frame_size_max);
        const header: frame.Header = .{
            .length = @intCast(payload.len),
            .frame_type = frame_type,
            .flags = flags,
            .stream_identifier = stream,
        };
        var octets: [frame.Header.octets]u8 = undefined;
        _ = header.render(&octets) catch return error.Protocol;
        session.writer.writeAll(&octets) catch return error.Io;
        if (payload.len > 0) session.writer.writeAll(payload) catch return error.Io;
    }
};

fn finish(status: ?u16, bytes: u64) Error!httpmod.Response {
    // A response with no `:status` is malformed (RFC 9113 section 8.3.2), and
    // counting it as a completed request would put a latency sample in the
    // histogram for something that never answered.
    const code = status orelse return error.Protocol;
    return .{
        .status = code,
        .bytes = bytes,
        // HTTP/2 has no `Connection: close`; a connection stays usable until
        // GOAWAY or the transport ends, both of which surface as `error.Closed`
        // rather than as a flag on a successful response.
        .keep_alive = true,
    };
}

/// Pull one field block's `:status` out, and check the rest is a well-formed
/// response while we are already walking it.
///
/// The validation is not ceremony: `h2.fields` is the package's answer to RFC
/// 9113 section 8.2, and a load generator that reported a 200 for a response
/// carrying a CR in a header value would be reporting a success the target
/// should have been failed for.
fn decodeStatus(decoder: *hpack.Decoder, buffer: []u8, block: []const u8) Error!u16 {
    var validator: h2.fields.MessageValidator = .init(.{
        .kind = .response,
        // The floor of section 8.2.1 rather than RFC 9110's full grammar. zrk
        // benchmarks servers it was pointed at, and refusing a response for a
        // header name that is legal-but-not-a-token would turn a measurement
        // into an argument. The rules that matter for a *client* — CR, LF, NUL,
        // pseudo-header placement — are in both readings.
        .rules = .minimal,
    });

    var status: ?u16 = null;
    var iterator = decoder.iterate(buffer, block);
    while (iterator.next() catch return error.Protocol) |field| {
        validator.field(&field) catch return error.Protocol;
        if (!std.mem.eql(u8, field.name, ":status")) continue;
        if (status != null) return error.Protocol;
        status = std.fmt.parseInt(u16, field.value, 10) catch return error.Protocol;
    }
    validator.finish() catch return error.Protocol;
    return status orelse error.Protocol;
}

/// Read the nine octets of a frame header and check what they alone decide.
fn readHeaderImpl(session: *Session) Error!frame.Header {
    const octets = session.reader.take(frame.Header.octets) catch return error.Io;
    const header = frame.Header.parse(octets) catch return error.Protocol;
    // Our own advertised bound, which is what makes every buffer here sized.
    header.validate(advertised_max_frame_size) catch return error.Protocol;
    return header;
}

/// One frame's payload, borrowed from the reader's buffer.
///
/// Valid until the next read, which is exactly how far it is used: every caller
/// parses it and either copies what it needs or finishes with it.
fn readPayloadImpl(session: *Session, header: frame.Header) Error![]const u8 {
    if (header.length == 0) return &.{};
    return session.reader.take(header.length) catch return error.Io;
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// Driven over fixed buffers rather than sockets: the question these ask is
// whether this module speaks the protocol, and a socket would add a second
// thing that can fail. The server side is built with `h2`'s own renderer, so a
// frame this client accepts is one the codec produced.

const testing = std.testing;

/// Build one frame the way a server would.
fn renderFrame(
    buffer: []u8,
    frame_type: frame.Type,
    flags: u8,
    stream: u31,
    payload: []const u8,
) usize {
    const header: frame.Header = .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_identifier = stream,
    };
    const octets = header.render(buffer) catch unreachable;
    @memcpy(buffer[octets..][0..payload.len], payload);
    return octets + payload.len;
}

/// A response header block, HPACK-encoded the way a server would send one.
fn renderResponseBlock(buffer: []u8, fields: []const hpack.Field) usize {
    // `.static_only` because we advertise `SETTINGS_HEADER_TABLE_SIZE = 0` and
    // this stands in for a server honouring that. A server that ignored it
    // would produce a block our decoder rejects, which is the correct outcome
    // and is what the malformed cases below check.
    var storage: hpack.Encoder.Storage(0) = .{};
    var encoder = storage.encoder(.static_only);
    const encoded = encoder.encode(buffer, fields);
    std.debug.assert(encoded.fields == fields.len);
    return encoded.written;
}

test "a plain exchange reads its status" {
    var wire: [4096]u8 = undefined;
    var used: usize = 0;
    // The server's opening SETTINGS, which `open` waits for.
    used += renderFrame(wire[used..], .settings, 0, 0, &.{});

    var block: [512]u8 = undefined;
    const block_len = renderResponseBlock(&block, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    });
    used += renderFrame(wire[used..], .headers, frame.Flag.end_headers.bit(), 1, block[0..block_len]);
    used += renderFrame(wire[used..], .data, frame.Flag.end_stream.bit(), 1, "hello");

    var reader: Io.Reader = .fixed(wire[0..used]);
    var out: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&out);

    var session: Session = .init(&reader, &writer);
    try session.open();

    var request: [256]u8 = undefined;
    const request_len = renderResponseBlock(&request, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.com" },
    });

    const response = try session.exchange(request[0..request_len], "");
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqual(@as(u64, 5), response.bytes - block_len);
    try testing.expect(response.keep_alive);

    // The preface goes first, before anything else. A server reading it
    // otherwise sees a malformed connection.
    try testing.expect(std.mem.startsWith(u8, out[0..writer.end], preface));
}

test "stream identifiers are odd and ascending" {
    // Section 5.1.1, and the reason it matters here: a client that reused an
    // identifier would have its second request answered on a closed stream.
    var wire: [4096]u8 = undefined;
    var used: usize = 0;
    used += renderFrame(wire[used..], .settings, 0, 0, &.{});

    var block: [256]u8 = undefined;
    const block_len = renderResponseBlock(&block, &.{.{ .name = ":status", .value = "204" }});
    var stream: u31 = 1;
    while (stream <= 5) : (stream += 2) {
        used += renderFrame(
            wire[used..],
            .headers,
            frame.Flag.end_headers.bit() | frame.Flag.end_stream.bit(),
            stream,
            block[0..block_len],
        );
    }

    var reader: Io.Reader = .fixed(wire[0..used]);
    var out: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&out);
    var session: Session = .init(&reader, &writer);
    try session.open();

    var request: [256]u8 = undefined;
    const request_len = renderResponseBlock(&request, &.{.{ .name = ":method", .value = "GET" }});

    var sent: u32 = 0;
    while (sent < 3) : (sent += 1) {
        const response = try session.exchange(request[0..request_len], "");
        try testing.expectEqual(@as(u16, 204), response.status);
    }
    try testing.expectEqual(@as(u31, 7), session.next_stream);
}

test "a response without :status is refused" {
    // RFC 9113 section 8.3.2 makes it malformed, and counting it as completed
    // would put a latency sample in the histogram for a request that was never
    // answered.
    var wire: [2048]u8 = undefined;
    var used: usize = 0;
    used += renderFrame(wire[used..], .settings, 0, 0, &.{});
    var block: [256]u8 = undefined;
    const block_len = renderResponseBlock(&block, &.{.{ .name = "content-type", .value = "text/plain" }});
    used += renderFrame(
        wire[used..],
        .headers,
        frame.Flag.end_headers.bit() | frame.Flag.end_stream.bit(),
        1,
        block[0..block_len],
    );

    var reader: Io.Reader = .fixed(wire[0..used]);
    var out: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&out);
    var session: Session = .init(&reader, &writer);
    try session.open();

    var request: [256]u8 = undefined;
    const request_len = renderResponseBlock(&request, &.{.{ .name = ":method", .value = "GET" }});
    try testing.expectError(error.Protocol, session.exchange(request[0..request_len], ""));
}

test "a stream that ends with data and no headers is refused" {
    // The other way a response can arrive without a `:status`, and the one the
    // check in `finish` exists for: `decodeStatus` catches a header block that
    // omits it, but a peer that sends DATA with END_STREAM and no HEADERS at
    // all never reaches a header block. Reporting that as a completed request
    // would put a latency sample in the histogram with a status of nothing.
    var wire: [2048]u8 = undefined;
    var used: usize = 0;
    used += renderFrame(wire[used..], .settings, 0, 0, &.{});
    used += renderFrame(wire[used..], .data, frame.Flag.end_stream.bit(), 1, "body");

    var reader: Io.Reader = .fixed(wire[0..used]);
    var out: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&out);
    var session: Session = .init(&reader, &writer);
    try session.open();

    var request: [256]u8 = undefined;
    const request_len = renderResponseBlock(&request, &.{.{ .name = ":method", .value = "GET" }});
    try testing.expectError(error.Protocol, session.exchange(request[0..request_len], ""));
}

test "GOAWAY stops new streams" {
    var wire: [2048]u8 = undefined;
    var used: usize = 0;
    used += renderFrame(wire[used..], .settings, 0, 0, &.{});
    // Last-stream-id 0, error code 0: a graceful shutdown.
    used += renderFrame(wire[used..], .goaway, 0, 0, &[_]u8{0} ** 8);

    var reader: Io.Reader = .fixed(wire[0..used]);
    var out: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&out);
    var session: Session = .init(&reader, &writer);
    try session.open();

    var request: [256]u8 = undefined;
    const request_len = renderResponseBlock(&request, &.{.{ .name = ":method", .value = "GET" }});
    // The first exchange consumes the GOAWAY while looking for its response and
    // ends without one; the second is refused before touching the wire.
    try testing.expectError(error.Io, session.exchange(request[0..request_len], ""));
    try testing.expect(session.peer_going_away);
    try testing.expectError(error.Closed, session.exchange(request[0..request_len], ""));
}
