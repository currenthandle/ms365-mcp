// e2e/cases.zig — Aggregator that re-exports every test function.
//
// Tests live in cases/<feature>.zig — one file per feature area.
// e2e.zig calls everything via `cases.testFoo`, so this file keeps that
// surface stable while letting individual test files stay focused.

const protocol = @import("cases/protocol.zig");
const readonly = @import("cases/readonly.zig");
const drafts = @import("cases/drafts.zig");
const calendar = @import("cases/calendar.zig");
const email = @import("cases/email.zig");
const chat = @import("cases/chat.zig");
const channels = @import("cases/channels.zig");
const sharepoint = @import("cases/sharepoint.zig");
const onedrive = @import("cases/onedrive.zig");
const journeys = @import("cases/journeys.zig");

// Protocol + auth.
pub const testInitialize = protocol.testInitialize;
pub const testCheckAuth = protocol.testCheckAuth;
pub const testLogin = protocol.testLogin;

// Read-only smoke tests.
pub const testListEmails = readonly.testListEmails;
pub const testListChats = readonly.testListChats;
pub const testListTeams = readonly.testListTeams;
pub const testGetProfile = readonly.testGetProfile;
pub const testSearchUsers = readonly.testSearchUsers;
pub const testGetMailboxSettings = readonly.testGetMailboxSettings;
pub const testSyncTimezone = readonly.testSyncTimezone;

// Drafts.
pub const testDraftLifecycle = drafts.testDraftLifecycle;
pub const testUpdateDraftLifecycle = drafts.testUpdateDraftLifecycle;
pub const testAttachmentLifecycle = drafts.testAttachmentLifecycle;
pub const testSendDraftLifecycle = drafts.testSendDraftLifecycle;
pub const testRemoveAttachmentLifecycle = drafts.testRemoveAttachmentLifecycle;

// Calendar.
pub const testCalendarLifecycle = calendar.testCalendarLifecycle;
pub const testCalendarWithAttendees = calendar.testCalendarWithAttendees;
pub const testCalendarListAndUpdate = calendar.testCalendarListAndUpdate;
pub const testGetSchedule = calendar.testGetSchedule;
pub const testFindMeetingTimes = calendar.testFindMeetingTimes;
pub const testRespondToEvent = calendar.testRespondToEvent;

// Email.
pub const testSendEmailLifecycle = email.testSendEmailLifecycle;
pub const testEmailReplyLifecycle = email.testEmailReplyLifecycle;
pub const testEmailForwardLifecycle = email.testEmailForwardLifecycle;
pub const testEmailSearch = email.testEmailSearch;
pub const testListMailFolders = email.testListMailFolders;
pub const testMarkReadLifecycle = email.testMarkReadLifecycle;
pub const testMoveEmailLifecycle = email.testMoveEmailLifecycle;
pub const testEmailAttachmentDownload = email.testEmailAttachmentDownload;

// Chat.
pub const testChatMessageLifecycle = chat.testChatMessageLifecycle;

// Channels.
pub const testChannelLifecycle = channels.testChannelLifecycle;
pub const testReplyToChannelMessage = channels.testReplyToChannelMessage;

// SharePoint.
pub const testSharePointLifecycle = sharepoint.testSharePointLifecycle;
pub const testSharePointFileUpload = sharepoint.testSharePointFileUpload;
pub const testSharePointLargeUpload = sharepoint.testSharePointLargeUpload;
pub const testSharePointItemIdTargeting = sharepoint.testSharePointItemIdTargeting;
pub const testSharePointPathValidation = sharepoint.testSharePointPathValidation;

// OneDrive.
pub const testOneDriveLifecycle = onedrive.testOneDriveLifecycle;

// Cross-tool journeys.
pub const testChatJourneySearchAndSend = journeys.testChatJourneySearchAndSend;
pub const testBatchDeleteEmails = journeys.testBatchDeleteEmails;
