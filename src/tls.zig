//! TLS transport helpers layered over a plain `net.Stream`.
//!
//! `CaStore` holds the system CA bundle, loaded once and shared (read-mostly)
//! across all connections. `State` is a per-connection, pinned block of buffers
//! plus the TLS engine; it wraps a connected stream and exposes the decrypted
//! reader/writer that the HTTP layer talks to.
//!
//! ## Why zssl, and what this file therefore owns
//!
//! zssl is sans-I/O: it takes whole TLS records in and hands bytes out, and
//! owns no socket, no allocator and no entropy. That is the reason it can be
//! audited, and the reason this file is not a thin wrapper — everything zssl
//! deliberately declines to do lands here:
//!
//!   * **The `std.Io` adapter.** `Reader`/`Writer` below implement the two
//!     vtables zrk's HTTP layers consume, over a record buffer this file
//!     pumps from the socket.
//!   * **Trust.** zssl proves *possession* — that the peer holds the key its
//!     leaf certificate names. Proving *identity* — that the chain builds to
//!     a system anchor and the name matches — is the embedder's, and
//!     `verifyChain` below is zrk's answer, over `std.crypto.Certificate`.
//!     That is the same split `std.crypto.tls.Client` makes internally; here
//!     it is visible, which is the point.
//!   * **Entropy.** zssl draws none, so each handshake takes 64 bytes from
//!     `io.random`.
//!
//! ALPN is why any of this exists rather than `std.crypto.tls`: HTTP/2 over
//! TLS is selected by it (RFC 9113 §3.2), and `std.crypto.tls` has none, so
//! `--http2` could only ever have been cleartext. See zoxy-io/zrk#21.
//!
//! Nothing here imposes a timeout; a slow peer can stall a handshake or a read
//! indefinitely, and the right mechanism is `std.Io` cancellation.
//! `connection.zig` already owns that: `watchTimer` shuts the socket down, and
//! the cancellation surfaces here as a transport error.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Certificate = std.crypto.Certificate;
const zssl = @import("zssl");

const assert = std.debug.assert;

/// The system trust store, loaded once and shared by all connections.
///
/// Rescanning the OS trust store on every handshake would be fine for a
/// program that opens one connection and wrong for one that opens thousands,
/// so it is loaded once and then only read. Never mutated after `load`, which
/// is why nothing below takes the lock to read it.
pub const CaStore = struct {
    bundle: Certificate.Bundle,

    pub fn load(gpa: std.mem.Allocator, io: Io) !CaStore {
        var bundle: Certificate.Bundle = .empty;
        try bundle.rescan(gpa, io, Io.Timestamp.now(io, .real));
        return .{ .bundle = bundle };
    }

    pub fn deinit(self: *CaStore, gpa: std.mem.Allocator) void {
        self.bundle.deinit(gpa);
    }
};

/// Matching the cleartext path's buffers in `connection.zig`, so the two
/// transports frame identically and a response that fits one fits the other.
const read_buffer_bytes = 16 * 1024;
const write_buffer_bytes = 8 * 1024;

/// Must hold the server's whole certificate flight. zssl asserts a floor of
/// 8 KiB; real chains with a 4096-bit RSA leaf and two intermediates clear
/// that but not by much, so this is doubled from the floor rather than set at
/// it.
const reassembly_bytes = 16 * 1024;

/// One whole record, which is what `handleRecord` and `sendApplicationData`
/// both need to write into.
const out_bytes = zssl.ClientHandshake.out_bytes_min;

pub const HandshakeError = error{
    /// The chain did not build to a trusted anchor, the name did not match,
    /// or the leaf's own signature did not check out.
    CertificateVerificationFailed,
    /// The peer's bytes were not a TLS 1.3 handshake we could complete.
    TlsHandshakeFailed,
    /// The socket failed, or the peer went away mid-handshake.
    TransportFailed,
    /// A record or flight larger than the buffers sized for it.
    HandshakeTooLarge,
};

/// Per-connection TLS state. Must not be moved once `handshake` has run: the
/// reader and writer interfaces hold pointers into this struct's own buffers.
///
/// Allocated as one undefined block per connection (`stats.Fleet`), so `init`
/// must run before anything reads a field, and `handshake` may be re-run to
/// reconnect — it tears the previous session down first.
pub const State = struct {
    /// Whether `client` holds a session that owes a `deinit`. The first thing
    /// written, because everything else starts as undefined memory.
    live: bool,

    client: zssl.ClientHandshake,
    records: zssl.record_buffer.RecordBuffer,
    trust: Trust,

    io: Io,
    stream: net.Stream,

    /// Decrypted application bytes handed out by `handleRecord` and not yet
    /// copied to the caller. Views `out_read`, so it dies at the next read.
    pending: []const u8,
    /// Set once the peer's close_notify or a transport EOF landed.
    read_closed: bool,

    reader_impl: Reader,
    writer_impl: Writer,

    record_storage: [zssl.record.wire_record_bytes_max]u8,
    reassembly: [reassembly_bytes]u8,
    /// Two out buffers, not one. `handleRecord` decrypts *into* this buffer
    /// and returns a slice of it, so a write that sealed a record through the
    /// same buffer would overwrite plaintext a concurrent read still owed the
    /// caller. HTTP/1.1 alternates and would never notice; h2 interleaves and
    /// would, silently and rarely, which is the worst way to find it.
    out_read: [out_bytes]u8,
    out_write: [out_bytes]u8,
    read_storage: [read_buffer_bytes]u8,
    write_storage: [write_buffer_bytes]u8,

    /// Bring a freshly allocated block to a state where every other method is
    /// safe to call. Nothing else may read a field first.
    pub fn init(self: *State) void {
        self.live = false;
    }

    pub fn deinit(self: *State) void {
        if (!self.live) return;
        self.client.deinit();
        self.live = false;
    }

    /// Perform the TLS handshake over `stream`, offering `alpn`.
    ///
    /// When `insecure` is true neither the hostname nor the chain is verified
    /// (`-k`); zssl still proves the peer holds the key its leaf names unless
    /// there is no chain to check it against.
    pub fn handshake(
        self: *State,
        io: Io,
        gpa: std.mem.Allocator,
        stream: net.Stream,
        host: []const u8,
        insecure: bool,
        ca: ?*CaStore,
        alpn: []const []const u8,
    ) HandshakeError!void {
        _ = gpa;
        // Reconnects land here on a state that still owns the last session.
        self.deinit();

        self.io = io;
        self.stream = stream;
        self.pending = &.{};
        self.read_closed = false;
        self.records = .init(&self.record_storage);
        self.reader_impl = .init(self);
        self.writer_impl = .init(self);

        // `-k`, or a run with no trust store to check against, verifies
        // neither name nor chain. Everything else gets both.
        const verifying = !insecure and ca != null;
        self.trust = .{
            .io = io,
            .bundle = if (verifying) &ca.?.bundle else null,
            .host = host,
        };

        var entropy: [64]u8 = undefined;
        io.random(&entropy);
        self.client = .init(&.{
            .client_random = entropy[0..32].*,
            .x25519_private = entropy[32..64].*,
            // SNI is sent either way: a server that needs it to pick a
            // certificate needs it under `-k` too, and withholding it would
            // change which endpoint is being measured.
            .server_name = host,
            .alpn_protocols = alpn,
            .certificate_policy = if (verifying) .leaf_signature else .insecure_no_verification,
            .chain_verifier = if (verifying) self.trust.verifier() else null,
            .reassembly = &self.reassembly,
        });
        self.live = true;

        try self.transportWrite(self.client.start(&self.out_read));
        while (self.client.state != .connected) {
            const wire_record = try self.nextRecord();
            const event = self.client.handleRecord(wire_record, &self.out_read) catch |err|
                return self.trust.classify(err);
            switch (event) {
                .none, .ticket => {},
                .send => |bytes| try self.transportWrite(bytes),
                .connected => |flight| try self.transportWrite(flight),
                // Neither can arrive before `connected`; zssl answers
                // `UnexpectedMessage` for the first and we asked for no early
                // data, so this is a zssl bug rather than a peer's.
                .application_data => unreachable,
                .closed => return error.TransportFailed,
            }
        }
    }

    /// The protocol ALPN settled on, or null if the peer selected none.
    ///
    /// Checked by the caller rather than asserted here: a server that ignores
    /// the offer and answers HTTP/1.1 to an `h2` request is a real thing to
    /// meet, and a load generator should report it rather than crash on it.
    pub fn negotiatedAlpn(self: *State) ?[]const u8 {
        return self.client.alpnSelected();
    }

    pub fn reader(self: *State) *Io.Reader {
        return &self.reader_impl.interface;
    }

    pub fn writer(self: *State) *Io.Writer {
        return &self.writer_impl.interface;
    }

    // ── transport ────────────────────────────────────────────────────────

    /// Read straight into the record buffer's own writable region, so a
    /// record is staged once rather than copied through a second buffer.
    fn fillRecords(self: *State) HandshakeError!void {
        const room = self.records.writable();
        var data: [1][]u8 = .{room};
        const n = self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &data) catch
            return error.TransportFailed;
        if (n == 0) return error.TransportFailed;
        self.records.advance(n);
    }

    /// The next whole record off the wire.
    fn nextRecord(self: *State) HandshakeError![]const u8 {
        while (true) {
            if (self.records.next() catch return error.HandshakeTooLarge) |wire_record| {
                return wire_record;
            }
            try self.fillRecords();
        }
    }

    fn transportWrite(self: *State, bytes: []const u8) HandshakeError!void {
        var rest = bytes;
        while (rest.len != 0) {
            const data: [1][]const u8 = .{rest};
            const n = self.io.vtable.netWrite(
                self.io.userdata,
                self.stream.socket.handle,
                "",
                &data,
                1,
            ) catch return error.TransportFailed;
            rest = rest[n..];
        }
    }

    // ── application data ─────────────────────────────────────────────────

    const StreamError = error{ EndOfStream, Failed };

    /// Drive the record loop until it yields application bytes, or the
    /// session ends. The result views `out_read` and dies at the next call.
    fn nextApplicationData(self: *State) StreamError![]const u8 {
        if (self.read_closed) return error.EndOfStream;
        while (true) {
            const wire_record = self.nextRecord() catch |err| {
                self.read_closed = true;
                // A transport EOF after a complete response is how many
                // servers close; the caller distinguishes it by having
                // already parsed one.
                return if (err == error.TransportFailed) error.EndOfStream else error.Failed;
            };
            const event = self.client.handleRecord(wire_record, &self.out_read) catch {
                self.read_closed = true;
                return error.Failed;
            };
            switch (event) {
                // A zero-length record is legal and carries nothing; keep
                // reading rather than reporting a false end of stream.
                .application_data => |plaintext| if (plaintext.len != 0) return plaintext,
                // Post-handshake traffic: a KeyUpdate we must answer, or a
                // ticket we have no use for.
                .send => |bytes| self.transportWrite(bytes) catch {
                    self.read_closed = true;
                    return error.Failed;
                },
                .none, .ticket => {},
                .closed => {
                    self.read_closed = true;
                    return error.EndOfStream;
                },
                .connected => unreachable, // Already connected.
            }
        }
    }

    /// Seal `bytes` into records and put them on the wire. TLS caps a record's
    /// plaintext at 16 KiB (§5.1), so anything longer becomes several.
    fn sendApplicationData(self: *State, bytes: []const u8) Io.Writer.Error!void {
        var rest = bytes;
        while (rest.len != 0) {
            const take = @min(rest.len, zssl.record.plaintext_bytes_max);
            const sealed = self.client.sendApplicationData(rest[0..take], &self.out_write) catch
                return error.WriteFailed;
            self.transportWrite(sealed) catch return error.WriteFailed;
            rest = rest[take..];
        }
    }

    pub const Reader = struct {
        interface: Io.Reader,

        fn init(self: *State) Reader {
            return .{ .interface = .{
                .vtable = &.{ .stream = streamImpl },
                .buffer = &self.read_storage,
                .seek = 0,
                .end = 0,
            } };
        }

        /// Copy decrypted application data into `io_w`.
        ///
        /// This honours the `Io.Reader.stream` contract rather than repointing
        /// `io_r.buffer` at the plaintext in place. Repointing removes a copy
        /// but makes the reader's capacity equal to the current record's
        /// length, which breaks every stdlib path that buffers across records
        /// — `peek`, `takeDelimiterInclusive` and friends, which is precisely
        /// what zurl's response parser is built from.
        fn streamImpl(
            io_r: *Io.Reader,
            io_w: *Io.Writer,
            limit: Io.Limit,
        ) Io.Reader.StreamError!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
            const self: *State = @alignCast(@fieldParentPtr("reader_impl", r));

            if (self.pending.len == 0) {
                self.pending = self.nextApplicationData() catch |err| switch (err) {
                    error.EndOfStream => return error.EndOfStream,
                    error.Failed => return error.ReadFailed,
                };
            }
            // A short write leaves the remainder pending for the next call,
            // and an error leaves it whole: `pending` only advances by what
            // the destination accepted.
            const n = try io_w.write(limit.sliceConst(self.pending));
            self.pending = self.pending[n..];
            return n;
        }
    };

    pub const Writer = struct {
        interface: Io.Writer,

        fn init(self: *State) Writer {
            return .{ .interface = .{
                .vtable = &.{ .drain = drainImpl },
                .buffer = &self.write_storage,
            } };
        }

        fn drainImpl(
            io_w: *Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
            const self: *State = @alignCast(@fieldParentPtr("writer_impl", w));

            // Buffered plaintext first, then each slice, with the last
            // repeated `splat` times; `consume` subtracts the buffered part.
            var total: usize = 0;
            const buffered = io_w.buffered();
            if (buffered.len != 0) {
                try self.sendApplicationData(buffered);
                total += buffered.len;
            }
            if (data.len != 0) {
                for (data[0 .. data.len - 1]) |slice| {
                    try self.sendApplicationData(slice);
                    total += slice.len;
                }
                const last = data[data.len - 1];
                for (0..splat) |_| {
                    try self.sendApplicationData(last);
                    total += last.len;
                }
            }
            return io_w.consume(total);
        }
    };
};

/// zrk's half of the trust decision: the chain building and RFC 9525 name
/// matching zssl leaves to its embedder.
///
/// Reached through `ClientHandshake.Config.chain_verifier`, which shows the
/// peer's chain while its bytes are still live and takes a yes or no. The
/// reason for the failure is kept here because the callback can only answer
/// with a bool, and "which certificate error" is worth reporting.
const Trust = struct {
    io: Io,
    /// null when this connection verifies nothing (`-k`, or no trust store).
    bundle: ?*const Certificate.Bundle,
    host: []const u8,
    failed: bool = false,

    fn verifier(self: *Trust) zssl.ClientHandshake.ChainVerifier {
        return .{ .context = self, .verify = Trust.verify };
    }

    fn verify(context: *anyopaque, chain: zssl.certificate_list.CertificateList) bool {
        const self: *Trust = @ptrCast(@alignCast(context));
        const bundle = self.bundle orelse return true;
        verifyChain(bundle, chain, self.host, self.io) catch {
            self.failed = true;
            return false;
        };
        return true;
    }

    /// Turn a zssl handshake error into this file's vocabulary, using what
    /// the verifier recorded to tell "we refused the chain" apart from "the
    /// leaf's own signature did not check out" — zssl reports both as
    /// `BadCertificate`, and only the first is a trust decision zrk made.
    fn classify(self: *const Trust, err: anyerror) HandshakeError {
        if (self.failed) return error.CertificateVerificationFailed;
        return switch (err) {
            error.BadCertificate, error.BadSignature => error.CertificateVerificationFailed,
            error.BufferOverflow => error.HandshakeTooLarge,
            else => error.TlsHandshakeFailed,
        };
    }
};

const VerifyError = error{
    CertificateHostMismatch,
    CertificateIssuerNotFound,
    CertificateMalformed,
    CertificateNotTrusted,
};

/// Walk the peer's chain from leaf to anchor, the way `std.crypto.tls.Client`
/// does internally: the leaf's name must match the host, each certificate must
/// be signed by the next, and some certificate along the way must be signed by
/// something in the system bundle.
fn verifyChain(
    bundle: *const Certificate.Bundle,
    chain: zssl.certificate_list.CertificateList,
    host: []const u8,
    io: Io,
) VerifyError!void {
    const now_sec = Io.Timestamp.now(io, .real).toSeconds();
    var it = chain.iterator();
    var index: usize = 0;
    var previous: Certificate.Parsed = undefined;
    while (it.next() catch return error.CertificateMalformed) |der| : (index += 1) {
        const certificate: Certificate = .{ .buffer = der, .index = 0 };
        const subject = certificate.parse() catch return error.CertificateMalformed;
        if (index == 0) {
            // RFC 9525: the name is checked on the leaf and nowhere else.
            subject.verifyHostName(host) catch return error.CertificateHostMismatch;
        } else {
            // Each certificate must actually have issued the one before it,
            // so a peer cannot smuggle an unrelated trusted certificate into
            // the list to satisfy the anchor check below.
            previous.verify(subject, now_sec) catch return error.CertificateNotTrusted;
        }
        if (bundle.verify(subject, now_sec)) {
            return;
        } else |err| switch (err) {
            // Not an anchor: keep walking outward.
            error.CertificateIssuerNotFound => {},
            else => return error.CertificateNotTrusted,
        }
        previous = subject;
    }
    // Every certificate the peer sent, and none of them reached an anchor.
    return error.CertificateIssuerNotFound;
}

/// A self-signed P-256 leaf for `zrk.test`, valid until 2126, generated by
/// openssl and committed as DER so the tests need neither a network nor an
/// openssl on PATH. Throwaway material, never a credential.
const test_leaf_der = @embedFile("testdata/leaf.der");

/// A second self-signed leaf, unrelated to the first — a different key and a
/// different name — for the case where a chain's links do not actually sign
/// each other.
const test_unrelated_der = @embedFile("testdata/unrelated.der");

/// Frame one DER certificate as a §4.4.2 `certificate_list` — a u24 length
/// and an empty extensions block per entry — so a test can hand `verifyChain`
/// what the handshake would.
fn testChain(storage: []u8, certificates: []const []const u8) zssl.certificate_list.CertificateList {
    var index: usize = 0;
    for (certificates) |der| {
        std.mem.writeInt(u24, storage[index..][0..3], @intCast(der.len), .big);
        index += 3;
        @memcpy(storage[index..][0..der.len], der);
        index += der.len;
        std.mem.writeInt(u16, storage[index..][0..2], 0, .big);
        index += 2;
    }
    return .init(storage[0..index]);
}

test "verifyChain checks the name on the leaf, before the anchor" {
    var storage: [1024]u8 = undefined;
    const chain = testChain(&storage, &.{test_leaf_der});
    // An empty bundle trusts nothing, so a name that *matches* can only fail
    // by running out of chain — which is what separates the two branches.
    const empty: Certificate.Bundle = .empty;
    const io = std.testing.io;

    try std.testing.expectError(
        error.CertificateHostMismatch,
        verifyChain(&empty, chain, "not-zrk.test", io),
    );
    try std.testing.expectError(
        error.CertificateIssuerNotFound,
        verifyChain(&empty, chain, "zrk.test", io),
    );
    // The SAN carries two names and both must be honoured; a check that only
    // read the subject CN would pass the first and fail this.
    try std.testing.expectError(
        error.CertificateIssuerNotFound,
        verifyChain(&empty, chain, "www.zrk.test", io),
    );
}

test "verifyChain refuses a chain whose links do not sign each other" {
    // An unrelated certificate appended after the leaf. It did not issue the
    // leaf, so the link check must reject it rather than walking on to look
    // for an anchor — without that check a peer could append any certificate
    // it liked in order to reach one the bundle happens to trust.
    //
    // Not the leaf twice: a self-signed certificate *is* validly signed by
    // itself, so that pair is a legitimate link and proves nothing.
    var storage: [1024]u8 = undefined;
    const chain = testChain(&storage, &.{ test_leaf_der, test_unrelated_der });
    const empty: Certificate.Bundle = .empty;
    try std.testing.expectError(
        error.CertificateNotTrusted,
        verifyChain(&empty, chain, "zrk.test", std.testing.io),
    );
}

test "verifyChain rejects a malformed chain rather than trusting it" {
    // A length that overruns the buffer: the iterator errors, and the
    // failure must be a refusal, not a fall-through to "no issuer found".
    var storage: [16]u8 = .{ 0, 0xff, 0xff, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const chain = zssl.certificate_list.CertificateList.init(storage[0..6]);
    const empty: Certificate.Bundle = .empty;
    try std.testing.expectError(
        error.CertificateMalformed,
        verifyChain(&empty, chain, "zrk.test", std.testing.io),
    );
}

/// What to offer for each protocol, in preference order.
///
/// `http/1.1` is offered alongside `h2` so that a server without HTTP/2 answers
/// on the protocol it does have instead of failing the handshake — the caller
/// then sees the mismatch through `negotiatedAlpn` and can report it.
pub const alpn_http1: []const []const u8 = &.{"http/1.1"};
pub const alpn_http2: []const []const u8 = &.{ "h2", "http/1.1" };
