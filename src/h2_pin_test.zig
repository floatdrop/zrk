const std = @import("std");
const h2 = @import("h2");
test "the h2 pin is the build zrk asked for" {
    // The `-Dassertions=false` in build.zig, confirmed rather than assumed: a
    // dependency option that silently did not apply would cost the hot path
    // every one of h2's checks with nothing to show it.
    try std.testing.expect(!h2.assertions.enabled);
    // And the pieces this issue needs are actually reachable.
    _ = h2.frame.Header.octets;
    _ = h2.hpack.Encoder.Mode.static_only;
    _ = h2.fields.MessageValidator;
}
