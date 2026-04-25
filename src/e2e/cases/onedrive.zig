// e2e/cases/onedrive.zig — OneDrive personal-drive tests.

const std = @import("std");

const client_mod = @import("../client.zig");
const helpers = @import("../helpers.zig");
const runner = @import("../runner.zig");
const shared = @import("shared.zig");

const McpClient = client_mod.McpClient;
const pass = runner.pass;
const fail = runner.fail;
const skip = runner.skip;

const Allocator = std.mem.Allocator;

/// Test: OneDrive upload-content → list → download (binary-safe) → delete.
pub fn testOneDriveLifecycle(client: *McpClient) !void {
    // Use a unique path so back-to-back runs don't collide.
    const dest_path = "e2e-onedrive-probe.md";
    const payload = "Hello from the ms-mcp OneDrive e2e suite.";

    // Upload content.
    var up_buf: [1024]u8 = undefined;
    const up_args = std.fmt.bufPrint(
        &up_buf,
        "{{\"path\":\"{s}\",\"content\":\"{s}\"}}",
        .{ dest_path, payload },
    ) catch return;
    const up = try client.callTool("upload-onedrive-content", up_args);
    defer up.deinit();
    const up_text = McpClient.getResultText(up) orelse {
        fail("upload-onedrive-content", "no text");
        return;
    };
    if (std.mem.indexOf(u8, up_text, "\"id\"") != null) {
        pass("upload-onedrive-content");
    } else {
        fail("upload-onedrive-content", up_text);
        return;
    }

    // OneDrive has a short indexing lag — poll up to 4 times with 2s
    // between calls before declaring the probe missing.
    var attempts: usize = 0;
    var found_in_list = false;
    while (attempts < 4 and !found_in_list) : (attempts += 1) {
        if (attempts > 0) _ = std.c.nanosleep(&.{ .sec = 2, .nsec = 0 }, null);
        const list = try client.callTool("list-onedrive-items", null);
        defer list.deinit();
        const list_text = McpClient.getResultText(list) orelse continue;
        if (std.mem.indexOf(u8, list_text, dest_path) != null) {
            found_in_list = true;
        }
    }
    if (found_in_list) {
        pass("list-onedrive-items (found probe)");
    } else {
        fail("list-onedrive-items", "probe not in list after 8s of polling");
    }

    // Download and verify bytes.
    var dl_buf: [512]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"path\":\"{s}\"}}", .{dest_path}) catch return;
    const dl = try client.callTool("download-onedrive-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-onedrive-file", "no text");
        return;
    };
    const local_path = helpers.extractAfterMarker(client.allocator, dl_text, "local_path: ") orelse {
        // Print the actual response so we can debug the mismatch.
        const debug_len = @min(dl_text.len, 300);
        std.debug.print("  DEBUG dl_text: {s}\n", .{dl_text[0..debug_len]});
        fail("download-onedrive-file", "no local_path");
        return;
    };
    defer client.allocator.free(local_path);
    const buf = client.allocator.alloc(u8, 65536) catch return;
    defer client.allocator.free(buf);
    const read_bytes = std.Io.Dir.cwd().readFile(client.io, local_path, buf) catch {
        fail("download-onedrive-file", "could not read temp file");
        return;
    };
    if (std.mem.indexOf(u8, read_bytes, "OneDrive e2e") != null) {
        pass("download-onedrive-file (bytes verified)");
    } else {
        fail("download-onedrive-file", "content mismatch");
    }

    // Cleanup.
    var del_buf: [512]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"path\":\"{s}\"}}", .{dest_path}) catch return;
    const del = try client.callTool("delete-onedrive-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-onedrive-item", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-onedrive-item");
    } else {
        fail("delete-onedrive-item", del_text);
    }
}

// ============================================================================
// Cross-tool journeys — chain multiple tools the way an agent would
// ============================================================================
