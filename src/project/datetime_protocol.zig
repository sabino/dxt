//! Native temporal carriers cannot be constructed by authored dictionary keys.
const std = @import("std");
const Value = @import("expression.zig").Value;
pub const Kind = enum { date, datetime, time, timedelta };
pub fn kind(value: Value) ?Kind {
    const tag_value = value.attribute("__dxt_temporal_value");
    if (tag_value != .callable) return null;
    const prefix = "__dxt_temporal_value:";
    if (!std.mem.startsWith(u8, tag_value.callable, prefix)) return null;
    return std.meta.stringToEnum(Kind, tag_value.callable[prefix.len..]);
}
pub fn marker(comptime temporal_kind: Kind) Value {
    return .{ .callable = "__dxt_temporal_value:" ++ @tagName(temporal_kind) };
}
