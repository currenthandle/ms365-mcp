// e2e/cases/sharepoint.zig — SharePoint upload, download, folder, validation tests.

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

/// Test: SharePoint full lifecycle — search site, list drive, create folder,
/// upload content, list, download + verify, delete file, delete folder.
///
/// Requires `E2E_SHAREPOINT_SITE_NAME` env var (a keyword that matches at
/// least one site the logged-in user can access). Skipped if unset.
pub fn testSharePointLifecycle(client: *McpClient) !void {
    const site_query = std.mem.span(std.c.getenv("E2E_SHAREPOINT_SITE_NAME").?);

    // --- Find a site ---
    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse {
        fail("search-sharepoint-sites", "no text");
        return;
    };
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse {
        fail("search-sharepoint-sites", "no site matched E2E_SHAREPOINT_SITE_NAME — check the .env value");
        return;
    };
    defer client.allocator.free(site_id);
    pass("search-sharepoint-sites");

    // --- List drives ---
    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse {
        fail("list-sharepoint-drives", "no text");
        return;
    };
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse {
        fail("list-sharepoint-drives", "no drive in site");
        return;
    };
    defer client.allocator.free(drive_id);
    pass("list-sharepoint-drives");

    // --- Create a test folder at the drive root ---
    const folder_path = "e2e-test-folder";
    var folder_buf: [1024]u8 = undefined;
    const folder_args = std.fmt.bufPrint(&folder_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const folder = try client.callTool("create-sharepoint-folder", folder_args);
    defer folder.deinit();
    const folder_text = McpClient.getResultText(folder) orelse {
        fail("create-sharepoint-folder", "no text");
        return;
    };
    if (std.mem.indexOf(u8, folder_text, "\"id\"") != null) {
        pass("create-sharepoint-folder");
    } else {
        fail("create-sharepoint-folder", folder_text);
        return;
    }

    // --- Upload a small content file ---
    const test_content = "Hello from the ms-mcp e2e suite. If you see this in SharePoint, something failed to clean up.";
    var upload_buf: [2048]u8 = undefined;
    const upload_args = std.fmt.bufPrint(
        &upload_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}/hello.md\",\"content\":\"{s}\"}}",
        .{ site_id, drive_id, folder_path, test_content },
    ) catch return;
    const upload = try client.callTool("upload-sharepoint-content", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-content", "no text");
        return;
    };
    if (std.mem.indexOf(u8, upload_text, "\"id\"") != null) {
        pass("upload-sharepoint-content");
    } else {
        fail("upload-sharepoint-content", upload_text);
        return;
    }

    // --- List items in the folder to confirm upload appeared ---
    var list_buf: [1024]u8 = undefined;
    const list_args = std.fmt.bufPrint(&list_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"folderPath\":\"{s}\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const list = try client.callTool("list-sharepoint-items", list_args);
    defer list.deinit();
    const list_text = McpClient.getResultText(list) orelse {
        fail("list-sharepoint-items", "no text");
        return;
    };
    if (std.mem.indexOf(u8, list_text, "hello.md") != null) {
        pass("list-sharepoint-items (found uploaded file)");
    } else {
        fail("list-sharepoint-items", "hello.md not in response");
    }

    // --- Download and verify content ---
    var dl_buf: [1024]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}/hello.md\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const dl = try client.callTool("download-sharepoint-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-sharepoint-file", "no text");
        return;
    };
    // download-sharepoint-file writes bytes to a temp path and returns
    // metadata. Read the temp file back and check the bytes.
    const dl_bytes = helpers.readDownloadedFile(client.allocator, client.io, dl_text) orelse {
        fail("download-sharepoint-file", "could not read the downloaded file from its local_path");
        return;
    };
    defer client.allocator.free(dl_bytes);
    if (std.mem.indexOf(u8, dl_bytes, "ms-mcp e2e suite") != null) {
        pass("download-sharepoint-file (verified content)");
    } else {
        fail("download-sharepoint-file", "downloaded bytes did not match uploaded content");
    }

    // --- Delete the file ---
    var del_file_buf: [1024]u8 = undefined;
    const del_file_args = std.fmt.bufPrint(&del_file_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}/hello.md\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const del_file = try client.callTool("delete-sharepoint-item", del_file_args);
    defer del_file.deinit();
    const del_file_text = McpClient.getResultText(del_file) orelse {
        fail("delete-sharepoint-item (file)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_file_text, "deleted") != null) {
        pass("delete-sharepoint-item (file)");
    } else {
        fail("delete-sharepoint-item (file)", del_file_text);
    }

    // --- Delete the folder ---
    var del_folder_buf: [1024]u8 = undefined;
    const del_folder_args = std.fmt.bufPrint(&del_folder_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, folder_path }) catch return;
    const del_folder = try client.callTool("delete-sharepoint-item", del_folder_args);
    defer del_folder.deinit();
    const del_folder_text = McpClient.getResultText(del_folder) orelse {
        fail("delete-sharepoint-item (folder)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_folder_text, "deleted") != null) {
        pass("delete-sharepoint-item (folder cleanup)");
    } else {
        fail("delete-sharepoint-item (folder cleanup)", del_folder_text);
    }
}


/// Test: upload a real file from disk (exercises readFileAlloc + MIME
/// inference + simple PUT path). Downloads and verifies bytes match.
pub fn testSharePointFileUpload(client: *McpClient) !void {
    const site_query = if (std.c.getenv("E2E_SHAREPOINT_SITE_NAME")) |ptr| std.mem.span(ptr) else return;

    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse return;
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse return;
    defer client.allocator.free(site_id);

    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse return;
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse return;
    defer client.allocator.free(drive_id);

    // Upload build.zig from the repo as the test payload.
    const dest_path = "e2e-file-upload.zig";
    var upload_buf: [2048]u8 = undefined;
    const upload_args = std.fmt.bufPrint(
        &upload_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\",\"filePath\":\"build.zig\"}}",
        .{ site_id, drive_id, dest_path },
    ) catch return;
    const upload = try client.callTool("upload-sharepoint-file", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-file", "no text");
        return;
    };
    if (std.mem.indexOf(u8, upload_text, "\"id\"") != null) {
        pass("upload-sharepoint-file");
    } else {
        fail("upload-sharepoint-file", upload_text);
        return;
    }

    // Download and confirm the content is what we uploaded (check a known
    // substring from build.zig).
    var dl_buf: [1024]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, dest_path }) catch return;
    const dl = try client.callTool("download-sharepoint-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-sharepoint-file (from disk)", "no text");
        return;
    };
    const dl_bytes = helpers.readDownloadedFile(client.allocator, client.io, dl_text) orelse {
        fail("download-sharepoint-file (from disk)", "could not read the downloaded file from its local_path");
        return;
    };
    defer client.allocator.free(dl_bytes);
    if (std.mem.indexOf(u8, dl_bytes, "pub fn build") != null) {
        pass("download-sharepoint-file (verified disk upload bytes)");
    } else {
        fail("download-sharepoint-file (from disk)", "build.zig content not found in downloaded bytes");
    }

    // Cleanup.
    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, dest_path }) catch return;
    const del = try client.callTool("delete-sharepoint-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse return;
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-sharepoint-item (file-upload cleanup)");
    } else {
        fail("delete-sharepoint-item (file-upload cleanup)", del_text);
    }
}


/// Test: large-file upload (>4MB) — exercises createUploadSession + chunked
/// PUTs. Builds a 5 MB string in memory to trigger the chunked path.
pub fn testSharePointLargeUpload(client: *McpClient) !void {
    const site_query = if (std.c.getenv("E2E_SHAREPOINT_SITE_NAME")) |ptr| std.mem.span(ptr) else return;

    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse return;
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse return;
    defer client.allocator.free(site_id);

    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse return;
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse return;
    defer client.allocator.free(drive_id);

    // Build a 5 MB payload: repeat "A" 5 * 1024 * 1024 times.
    // (Stays a valid JSON string — every byte is printable ASCII.)
    const large_size: usize = 5 * 1024 * 1024;
    const payload = client.allocator.alloc(u8, large_size) catch {
        fail("upload-sharepoint-content (large)", "alloc failed");
        return;
    };
    defer client.allocator.free(payload);
    @memset(payload, 'A');

    const dest_path = "e2e-large-upload.txt";
    // args are tool args: {siteId, driveId, path, content}. We allocate an
    // args buffer big enough to hold the JSON wrapper plus the 5 MB payload.
    const args_size = 1024 + large_size;
    const args_buf = client.allocator.alloc(u8, args_size) catch return;
    defer client.allocator.free(args_buf);
    const upload_args = std.fmt.bufPrint(
        args_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\",\"content\":\"{s}\"}}",
        .{ site_id, drive_id, dest_path, payload },
    ) catch {
        fail("upload-sharepoint-content (large)", "args build failed");
        return;
    };
    const upload = try client.callTool("upload-sharepoint-content", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-content (large)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, upload_text, "\"id\"") != null) {
        pass("upload-sharepoint-content (5MB, chunked)");
    } else {
        fail("upload-sharepoint-content (large)", upload_text);
        return;
    }

    // Cleanup.
    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\"}}", .{ site_id, drive_id, dest_path }) catch return;
    const del = try client.callTool("delete-sharepoint-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse return;
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-sharepoint-item (large-upload cleanup)");
    } else {
        fail("delete-sharepoint-item (large-upload cleanup)", del_text);
    }
}


/// Test: itemId targeting on download + delete — complements the path-based
/// targeting exercised in the main lifecycle.
pub fn testSharePointItemIdTargeting(client: *McpClient) !void {
    const site_query = if (std.c.getenv("E2E_SHAREPOINT_SITE_NAME")) |ptr| std.mem.span(ptr) else return;

    var search_buf: [512]u8 = undefined;
    const search_args = std.fmt.bufPrint(&search_buf, "{{\"query\":\"{s}\"}}", .{site_query}) catch return;
    const search = try client.callTool("search-sharepoint-sites", search_args);
    defer search.deinit();
    const search_text = McpClient.getResultText(search) orelse return;
    const site_id = helpers.extractFirstValueField(client.allocator, search_text, "id") orelse return;
    defer client.allocator.free(site_id);

    var drives_buf: [512]u8 = undefined;
    const drives_args = std.fmt.bufPrint(&drives_buf, "{{\"siteId\":\"{s}\"}}", .{site_id}) catch return;
    const drives = try client.callTool("list-sharepoint-drives", drives_args);
    defer drives.deinit();
    const drives_text = McpClient.getResultText(drives) orelse return;
    const drive_id = helpers.extractFirstValueField(client.allocator, drives_text, "id") orelse return;
    defer client.allocator.free(drive_id);

    // Upload.
    const dest_path = "e2e-itemid-test.md";
    const marker = "Marker content for itemId targeting test.";
    var upload_buf: [2048]u8 = undefined;
    const upload_args = std.fmt.bufPrint(
        &upload_buf,
        "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"path\":\"{s}\",\"content\":\"{s}\"}}",
        .{ site_id, drive_id, dest_path, marker },
    ) catch return;
    const upload = try client.callTool("upload-sharepoint-content", upload_args);
    defer upload.deinit();
    const upload_text = McpClient.getResultText(upload) orelse {
        fail("upload-sharepoint-content (itemId test)", "no text");
        return;
    };
    const item_id = helpers.extractJsonString(client.allocator, upload_text, "id") orelse {
        fail("upload-sharepoint-content (itemId test)", "no id in response");
        return;
    };
    defer client.allocator.free(item_id);
    pass("upload-sharepoint-content (itemId test setup)");

    // Download by itemId.
    var dl_buf: [1024]u8 = undefined;
    const dl_args = std.fmt.bufPrint(&dl_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"itemId\":\"{s}\"}}", .{ site_id, drive_id, item_id }) catch return;
    const dl = try client.callTool("download-sharepoint-file", dl_args);
    defer dl.deinit();
    const dl_text = McpClient.getResultText(dl) orelse {
        fail("download-sharepoint-file (by itemId)", "no text");
        return;
    };
    const dl_bytes = helpers.readDownloadedFile(client.allocator, client.io, dl_text) orelse {
        fail("download-sharepoint-file (by itemId)", "could not read the downloaded file from its local_path");
        return;
    };
    defer client.allocator.free(dl_bytes);
    if (std.mem.indexOf(u8, dl_bytes, marker) != null) {
        pass("download-sharepoint-file (by itemId)");
    } else {
        fail("download-sharepoint-file (by itemId)", "marker not in downloaded bytes");
    }

    // Delete by itemId.
    var del_buf: [1024]u8 = undefined;
    const del_args = std.fmt.bufPrint(&del_buf, "{{\"siteId\":\"{s}\",\"driveId\":\"{s}\",\"itemId\":\"{s}\"}}", .{ site_id, drive_id, item_id }) catch return;
    const del = try client.callTool("delete-sharepoint-item", del_args);
    defer del.deinit();
    const del_text = McpClient.getResultText(del) orelse {
        fail("delete-sharepoint-item (by itemId)", "no text");
        return;
    };
    if (std.mem.indexOf(u8, del_text, "deleted") != null) {
        pass("delete-sharepoint-item (by itemId)");
    } else {
        fail("delete-sharepoint-item (by itemId)", del_text);
    }
}


/// Test: path validation — negative cases, no network. Verifies the
/// server rejects unsafe paths before hitting Graph.
pub fn testSharePointPathValidation(client: *McpClient) !void {
    const cases_list = [_]struct { name: []const u8, path: []const u8, expected_snippet: []const u8 }{
        .{ .name = "rejects leading slash", .path = "/foo", .expected_snippet = "must not start with" },
        .{ .name = "rejects .. segment", .path = "a/../b", .expected_snippet = "must not start with" },
        .{ .name = "rejects empty path", .path = "", .expected_snippet = "Missing" },
    };
    for (cases_list) |tc| {
        var buf: [1024]u8 = undefined;
        const args = std.fmt.bufPrint(
            &buf,
            "{{\"siteId\":\"fake\",\"driveId\":\"fake\",\"path\":\"{s}\",\"content\":\"hi\"}}",
            .{tc.path},
        ) catch continue;
        const resp = try client.callTool("upload-sharepoint-content", args);
        defer resp.deinit();
        const text = McpClient.getResultText(resp) orelse {
            fail(tc.name, "no text");
            continue;
        };
        if (std.mem.indexOf(u8, text, tc.expected_snippet) != null or
            std.mem.indexOf(u8, text, "Invalid") != null)
        {
            pass(tc.name);
        } else {
            fail(tc.name, text);
        }
    }
}

// ============================================================================
// Phase 4 — Email action tools (reply, forward, search, folders, mark, move,
//                               list-attachments, read-attachment)
// ============================================================================
