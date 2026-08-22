//! TLS transport helpers layered over a plain `net.Stream`.
//!
//! `CaStore` holds the system CA bundle, loaded once and shared (read-mostly)
//! across all connections. `State` is a per-connection, pinned block of buffers
//! plus the TLS client; it wraps a connected stream and exposes the decrypted
//! reader/writer that the HTTP layer talks to.
//!
//! ## Why ztls rather than `std.crypto.tls`
//!
//! ALPN. HTTP/2 over TLS is selected by it (RFC 9113 section 3.2) and
//! `std.crypto.tls` has none, so `--http2` could only ever have been cleartext.
//! That is the whole reason for the swap, and it is why `Options.alpn` is the
//! one field this wrapper adds to what it had before.
//!
//! The cost is real and was paid deliberately: ztls's primitives are
//! libcrypto's, so zrk now links C where it linked none, and ztls is Linux and
//! macOS by design — its entropy shim is an outright `@compileError` elsewhere,
//! which is why the Windows release targets were dropped. See zoxy-io/zrk#21.
//!
//! ztls-std imposes no timeout of its own; a slow peer can stall a handshake or
//! a read indefinitely, and the right mechanism is `std.Io` cancellation.
//! `connection.zig` already owns that: `watchTimer` shuts the socket down, and
//! the cancellation surfaces here as a transport error.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Certificate = std.crypto.Certificate;
const ztls = @import("ztls_std");

/// The system trust store, loaded once and shared by all connections.
///
/// `Verify.system_bundle` would rescan the OS trust store on every handshake
/// and free it again — fine for a program that opens one connection, wrong for
/// one that opens thousands. This is the `.bundle` case ztls-std documents for
/// exactly that reason.
pub const CaStore = struct {
    bundle: Certificate.Bundle,
    lock: Io.RwLock = .init,

    pub fn load(gpa: std.mem.Allocator, io: Io) !CaStore {
        var bundle: Certificate.Bundle = .empty;
        try bundle.rescan(gpa, io, Io.Timestamp.now(io, .real));
        return .{ .bundle = bundle };
    }

    pub fn deinit(self: *CaStore, gpa: std.mem.Allocator) void {
        self.bundle.deinit(gpa);
    }
};

/// The TLS client, with buffers sized for one HTTP exchange at a time.
///
/// `peer_chain_storage` is left null: retaining the verified chain costs about
/// 64 KiB per connection and zrk never reports it. A load generator holds
/// hundreds of these at once, so the default that suits a demo client is the
/// wrong one here.
const Client = ztls.ClientWith(.{});

/// Per-connection TLS state. Must not be moved once `handshake` has run, since
/// the client stores pointers into its own buffers and stream adapters.
/// Reused across reconnects by simply re-running `handshake`.
pub const State = struct {
    client: Client = undefined,

    pub const HandshakeError = ztls.ConnectError;

    /// Perform the TLS handshake over `stream`, offering `alpn`.
    ///
    /// When `insecure` is true neither the hostname nor the certificate chain
    /// is verified (`-k`). Note that `.insecure` in ztls-std skips the chain
    /// anchor but still verifies the hostname unless `host` is null, so `-k`
    /// passes null to get what `-k` has always meant here.
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
        // A bundle we own, never `.system_bundle`: see `CaStore`.
        const verify: ztls.Verify = if (insecure or ca == null)
            .insecure
        else
            .{ .bundle = &ca.?.bundle };

        try self.client.connect(io, stream, .{
            .host = if (insecure) null else host,
            .verify = verify,
            .alpn = alpn,
        });
    }

    /// The protocol ALPN settled on, or null if the peer selected none.
    ///
    /// Checked by the caller rather than asserted here: a server that ignores
    /// the offer and answers HTTP/1.1 to an `h2` request is a real thing to
    /// meet, and a load generator should report it rather than crash on it.
    pub fn negotiatedAlpn(self: *State) ?[]const u8 {
        return self.client.info().alpn;
    }

    pub fn reader(self: *State) *Io.Reader {
        return self.client.reader();
    }

    pub fn writer(self: *State) *Io.Writer {
        return self.client.writer();
    }
};

/// What to offer for each protocol, in preference order.
///
/// `http/1.1` is offered alongside `h2` so that a server without HTTP/2 answers
/// on the protocol it does have instead of failing the handshake — the caller
/// then sees the mismatch through `negotiatedAlpn` and can report it.
pub const alpn_http1: []const []const u8 = &.{"http/1.1"};
pub const alpn_http2: []const []const u8 = &.{ "h2", "http/1.1" };
