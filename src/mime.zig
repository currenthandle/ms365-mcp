// mime.zig — MIME-type inference from a file path's extension.
//
// Used by draft attachments and SharePoint uploads. Covers the common
// office/image/text types; unknown extensions fall back to
// application/octet-stream, which Graph accepts.

const std = @import("std");

/// Infer MIME type from file extension.
pub fn fromPath(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".doc")) return "application/msword";
    if (std.mem.eql(u8, ext, ".docx")) return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    if (std.mem.eql(u8, ext, ".xls")) return "application/vnd.ms-excel";
    if (std.mem.eql(u8, ext, ".xlsx")) return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    if (std.mem.eql(u8, ext, ".ppt")) return "application/vnd.ms-powerpoint";
    if (std.mem.eql(u8, ext, ".pptx")) return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain";
    if (std.mem.eql(u8, ext, ".md")) return "text/markdown";
    if (std.mem.eql(u8, ext, ".csv")) return "text/csv";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html";
    if (std.mem.eql(u8, ext, ".zip")) return "application/zip";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    return "application/octet-stream";
}
