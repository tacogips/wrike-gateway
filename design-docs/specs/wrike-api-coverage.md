# Wrike API v4 Coverage Inventory

Recorded 2026-08-06 against the official reference index
(`https://developers.wrike.com/llms.txt`, reference pages last modified
2026-02-24) and the capability definitions in `Sources/WrikeGatewayRead`,
`Sources/WrikeGatewayWrite`, and `Sources/WrikeGatewayAdmin`.

This document is the endpoint-level bird's-eye view: every operation the
official Wrike API v4 REST reference lists, and whether this gateway
implements it. It complements `design-capability-matrix.md`, which records the
tier rules and the reviewed capability ids; this file tracks the whole
upstream surface including families the matrix never adopted.

Legend:

- `✅ reader` / `✅ writer` / `✅ admin` — implemented, with the tier that
  exposes it and the capability id.
- `❌` — not implemented; no capability id exists.
- Scope-variant rows (e.g. `GET /folders/{id}/tasks`) are listed separately
  because the official reference documents them as separate operations, even
  when one capability covers several via `ScopeVariant` routing.

## Summary

| Section | Implemented | Total | Notes |
| --- | ---: | ---: | --- |
| Access Roles | 1 | 1 | |
| Account | 2 | 2 | |
| Approvals | 0 | 8 | whole family missing |
| Assets & Equipment | 0 | 3 | whole family missing |
| Async Job / Batch | 0 | 2 | whole family missing |
| Attachments | 11 | 11 | complete |
| Audit Log | 0 | 1 | whole family missing |
| Bookings | 0 | 6 | whole family missing |
| Cascading Fields | 0 | 4 | whole family missing |
| Colors | 0 | 1 | |
| Comments | 8 | 8 | complete |
| Contacts | 4 | 4 | complete |
| Custom Fields | 5 | 5 | complete |
| Custom Item Types | 0 | 4 | whole family missing |
| Data Export | 0 | 4 | whole family missing |
| Dependencies | 0 | 5 | whole family missing |
| eDiscovery | 0 | 1 | |
| Folder Blueprints | 0 | 3 | whole family missing |
| Folders & Projects | 9 | 11 | bulk update, copy-async missing |
| Groups | 5 | 6 | bulk modify missing |
| Hourly Rates & Budget | 0 | 7 | whole family missing |
| ID Conversion (v2 → v4) | 0 | 1 | |
| Invitations | 0 | 4 | whole family missing |
| Job Roles | 0 | 5 | whole family missing |
| Placeholders | 0 | 2 | whole family missing |
| Request Forms | 0 | 5 | whole family missing |
| Rollup Settings | 0 | 4 | whole family missing |
| Spaces | 5 | 5 | complete |
| Task Blueprints | 0 | 3 | whole family missing |
| Tasks | 8 | 9 | bulk update missing |
| Timelog Categories | 0 | 1 | |
| Timelog Locks | 0 | 7 | whole family missing |
| Timelogs | 9 | 9 | complete |
| Timesheets & Submission Rules | 0 | 7 | whole family missing |
| User Schedules (capacity / exceptions / partial) | 0 | 15 | whole family missing |
| User Types | 1 | 1 | |
| Users | 2 | 3 | bulk activate/deactivate missing |
| Version | 0 | 1 | |
| Webhooks | 5 | 5 | complete |
| Work Schedules (incl. capacity / exceptions) | 0 | 16 | whole family missing |
| Workflows | 3 | 4 | space-scoped list missing |
| **Total (API v4 REST)** | **78** | **204** | **≈38%** |

The table-based Databases/Records API, Search Tags, and the DAM API are
separate Wrike API families outside the v4 REST surface; they are listed at
the end and are entirely unimplemented.

## Access Roles

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Access Roles | `GET /access_roles` | ✅ reader `accessRoles.list` |

## Account

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Account | `GET /account` | ✅ reader `account.get` |
| Modify Account | `PUT /account` | ✅ writer `account.update` |

## Approvals

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Approvals (Account) | `GET /approvals` | ❌ |
| Get Approvals (Folder) | `GET /folders/{folderId}/approvals` | ❌ |
| Create Approval (Folder) | `POST /folders/{folderId}/approvals` | ❌ |
| Get Approvals (Task) | `GET /tasks/{taskId}/approvals` | ❌ |
| Create Approval (Task) | `POST /tasks/{taskId}/approvals` | ❌ |
| Get Approvals By ID | `GET /approvals/{approvalIds}` | ❌ |
| Update Approval | `PUT /approvals/{approvalId}` | ❌ |
| Cancel Approval | `DELETE /approvals/{approvalId}` | ❌ |

## Assets & Equipment

| Operation | Method and path | Status |
| --- | --- | --- |
| Create Equipment | `POST /assets` | ❌ |
| Update Equipment | `PUT /assets/{assetId}` | ❌ |
| Delete Equipment | `DELETE /assets/{assetId}` | ❌ |

## Async Job / Batch

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Async Job | `GET /async_job/{jobId}` | ❌ |
| Create Batch Operation | `POST /batch` | ❌ |

## Attachments

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Attachments (Account) | `GET /attachments` | ✅ reader `attachments.list` |
| Get Attachments (Folder) | `GET /folders/{folderId}/attachments` | ✅ reader `attachments.list` (folder/project scope) |
| Get Attachments (Task) | `GET /tasks/{taskId}/attachments` | ✅ reader `attachments.list` (task scope) |
| Get Attachments By ID | `GET /attachments/{attachmentIds}` | ✅ reader `attachments.get` |
| Download Attachment | `GET /attachments/{attachmentId}/download` | ✅ reader `attachments.download` |
| Preview Attachment | `GET /attachments/{attachmentId}/preview` | ✅ reader `attachments.preview` |
| Get Attachment URL | `GET /attachments/{attachmentId}/url` | ✅ reader `attachments.url` |
| Create Attachment (Folder) | `POST /folders/{folderId}/attachments` | ✅ writer `attachments.upload.folder` |
| Create Attachment (Task) | `POST /tasks/{taskId}/attachments` | ✅ writer `attachments.upload.task` |
| Update Attachment | `PUT /attachments/{attachmentId}` | ✅ writer `attachments.update` |
| Delete Attachment | `DELETE /attachments/{attachmentId}` | ✅ admin `attachments.delete` |

## Audit Log

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Audit Log | `GET /audit_log` | ❌ |

## Bookings

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Bookings (Account) | `GET /bookings` | ❌ |
| Get Bookings (Folder) | `GET /folders/{folderId}/bookings` | ❌ |
| Get Bookings By ID | `GET /bookings/{bookingIds}` | ❌ |
| Create Booking | `POST /folders/{folderId}/bookings` | ❌ |
| Update Booking | `PUT /bookings/{bookingId}` | ❌ |
| Delete Booking | `DELETE /bookings/{bookingId}` | ❌ |

## Cascading Fields

| Operation | Method and path | Status |
| --- | --- | --- |
| Trigger Field Cascading (Folders) | `POST /folders/{folderId}/cascading_field_settings` | ❌ |
| Delete Active Cascading Field Settings (Folders) | `DELETE /folders/{folderId}/cascading_field_settings` | ❌ |
| Trigger Field Cascading (Tasks) | `POST /tasks/{taskId}/cascading_field_settings` | ❌ |
| Delete Active Cascading Field Settings (Tasks) | `DELETE /tasks/{taskId}/cascading_field_settings` | ❌ |

## Colors

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Colors | `GET /colors` | ❌ |

## Comments

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Comments (Account) | `GET /comments` | ✅ reader `comments.list` |
| Get Comments (Folder) | `GET /folders/{folderId}/comments` | ✅ reader `comments.list` (folder/project scope) |
| Get Comments (Task) | `GET /tasks/{taskId}/comments` | ✅ reader `comments.list` (task scope) |
| Get Comments By ID | `GET /comments/{commentIds}` | ✅ reader `comments.get` |
| Create Comment (Folder) | `POST /folders/{folderId}/comments` | ✅ writer `comments.create` (folder/project scope) |
| Create Comment (Task) | `POST /tasks/{taskId}/comments` | ✅ writer `comments.create` (task scope) |
| Update Comment | `PUT /comments/{commentId}` | ✅ writer `comments.update` |
| Delete Comment | `DELETE /comments/{commentId}` | ✅ admin `comments.delete` |

## Contacts

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Contacts | `GET /contacts` | ✅ reader `contacts.list` |
| Query Contacts By ID | `GET /contacts/{contactIds}` | ✅ reader `contacts.get` |
| Query Contacts Fields History | `GET /contacts/{contactIds}/contacts_history` | ✅ reader `contacts.history` |
| Modify Contact | `PUT /contacts/{contactId}` | ✅ writer `contacts.update` |

## Custom Fields

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Custom Fields (Account) | `GET /customfields` | ✅ reader `customFields.list` |
| Get Custom Fields (Space) | `GET /spaces/{spaceId}/customfields` | ✅ reader `customFields.list` (space scope) |
| Get Custom Fields By ID | `GET /customfields/{customFieldIds}` | ✅ reader `customFields.get` |
| Create Custom Field | `POST /customfields` | ✅ writer `customFields.create` |
| Modify Custom Field | `PUT /customfields/{customFieldId}` | ✅ writer `customFields.update` |

## Custom Item Types

| Operation | Method and path | Status |
| --- | --- | --- |
| Query All Custom Item Types (Account) | `GET /custom_item_types` | ❌ |
| Query All Custom Item Types (Space) | `GET /spaces/{spaceId}/custom_item_types` | ❌ |
| Query Custom Item Types By ID | `GET /custom_item_types/{typeIds}` | ❌ |
| Create Work from Custom Item Type | `POST /custom_item_types/{typeId}/instantiate` | ❌ |

## Data Export

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Data Export | `GET /data_export` | ❌ |
| Refresh Data Export | `POST /data_export` | ❌ |
| Get Data Export By ID | `GET /data_export/{exportId}` | ❌ |
| Get Data Export Schema | `GET /data_export_schema` | ❌ |

## Dependencies

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Dependencies (Task) | `GET /tasks/{taskId}/dependencies` | ❌ |
| Create Dependency | `POST /tasks/{taskId}/dependencies` | ❌ |
| Get Dependencies By ID | `GET /dependencies/{dependencyIds}` | ❌ |
| Modify Dependency | `PUT /dependencies/{dependencyId}` | ❌ |
| Delete Dependency | `DELETE /dependencies/{dependencyId}` | ❌ |

## eDiscovery

| Operation | Method and path | Status |
| --- | --- | --- |
| eDiscovery Search | `POST /ediscovery_search` | ❌ |

## Folder Blueprints

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Folder Blueprints (Account) | `GET /folder_blueprints` | ❌ |
| Get Folder Blueprints (Space) | `GET /spaces/{spaceId}/folder_blueprints` | ❌ |
| Launch Folder Blueprint (Async) | `POST /folder_blueprints/{blueprintId}/launch_async` | ❌ |

## Folders & Projects

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Folders (Account) | `GET /folders` | ✅ reader `folders.list` / `projects.list` |
| Get Folders (Folder) | `GET /folders/{folderId}/folders` | ✅ reader `folders.list` (folder scope) |
| Get Folders (Space) | `GET /spaces/{spaceId}/folders` | ✅ reader `folders.list` (space scope) |
| Get Folder By ID | `GET /folders/{folderIds}` | ✅ reader `folders.get` / `projects.get` |
| Query Folders Fields History | `GET /folders/{folderIds}/folders_history` | ✅ reader `folders.history` |
| Create Folder | `POST /folders/{folderId}/folders` | ✅ writer `folders.create` / `projects.create` |
| Update Folder | `PUT /folders/{folderId}` | ✅ writer `folders.update` / `projects.update` |
| Update Folders (Bulk) | `PUT /folders/{folderIds}` | ❌ |
| Copy Folder | `POST /copy_folder/{folderId}` | ✅ writer `folders.copy` |
| Copy Folder Async | `POST /copy_folder_async/{folderId}` | ❌ |
| Delete Folder | `DELETE /folders/{folderId}` | ✅ admin `folders.delete` / `projects.delete` |

## Groups

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Groups (All) | `GET /groups` | ✅ reader `groups.list` |
| Query Group (Single) | `GET /groups/{groupId}` | ✅ reader `groups.get` |
| Create Group | `POST /groups` | ✅ writer `groups.create` |
| Modify Group | `PUT /groups/{groupId}` | ✅ writer `groups.update` |
| Bulk Modify Groups | `PUT /groups_bulk` | ❌ |
| Delete Group | `DELETE /groups/{groupId}` | ✅ admin `groups.delete` |

## Hourly Rates & Budget

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Budget Rates (Contacts) | `GET /contacts/{contactIds}/hourly_rates` | ❌ |
| Get Budget Rates (Folder) | `GET /folders/{folderId}/hourly_rates` | ❌ |
| Update Budget Rates (Folder) | `PUT /folders/{folderId}/hourly_rates` | ❌ |
| Get Budget Rates (Placeholders) | `GET /placeholders/{placeholderIds}/hourly_rates` | ❌ |
| Update Budget Rates (Account) | `PUT /hourly_rates` | ❌ |
| Exclude Team Members | `DELETE /folders/{folderId}/project_team_members` | ❌ |
| Provision Hourly Rates | `PUT /contacts/{contactIds}/hourly_rates_provision` | ❌ |

## ID Conversion

| Operation | Method and path | Status |
| --- | --- | --- |
| Legacy API v2 IDs Converter | `GET /ids` | ❌ |

## Invitations

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Invitations | `GET /invitations` | ❌ |
| Create Invitation | `POST /invitations` | ❌ |
| Update Invitation | `PUT /invitations/{invitationId}` | ❌ |
| Delete Invitation | `DELETE /invitations/{invitationId}` | ❌ |

## Job Roles

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Job Roles (Account) | `GET /jobroles` | ❌ |
| Get Job Roles By ID | `GET /jobroles/{jobRoleIds}` | ❌ |
| Create Job Role | `POST /jobroles` | ❌ |
| Update Job Role | `PUT /jobroles/{jobRoleId}` | ❌ |
| Delete Job Role | `DELETE /jobroles/{jobRoleId}` | ❌ |

## Placeholders

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Placeholders (Account) | `GET /placeholders` | ❌ |
| Get Placeholders By ID | `GET /placeholders/{placeholderIds}` | ❌ |

## Request Forms

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Request Forms (Account) | `GET /request_forms` | ❌ |
| Query Request Forms (Space) | `GET /spaces/{spaceId}/request_forms` | ❌ |
| Get Request Form By ID | `GET /request_forms/{formId}` | ❌ |
| Generate Prefilled Request Form URL | `POST /request_forms/{formId}/prefill_url` | ❌ |
| Submit Request Form | `POST /request_forms/{formId}/submit` | ❌ |

## Rollup Settings

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Rollup Settings (Folder) | `GET /folders/{folderIds}/rollups` | ❌ |
| Update Rollup Settings (Folder) | `PUT /folders/{folderId}/rollups` | ❌ |
| Get Rollup Settings (Task) | `GET /tasks/{taskIds}/rollups` | ❌ |
| Update Rollup Settings (Task) | `PUT /tasks/{taskId}/rollups` | ❌ |

## Spaces

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Spaces (Account) | `GET /spaces` | ✅ reader `spaces.list` |
| Get Space By ID | `GET /spaces/{spaceId}` | ✅ reader `spaces.get` |
| Create Space | `POST /spaces` | ✅ writer `spaces.create` |
| Update Space | `PUT /spaces/{spaceId}` | ✅ writer `spaces.update` |
| Delete Space | `DELETE /spaces/{spaceId}` | ✅ admin `spaces.delete` |

## Task Blueprints

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Task Blueprints (Account) | `GET /task_blueprints` | ❌ |
| Get Task Blueprints (Space) | `GET /spaces/{spaceId}/task_blueprints` | ❌ |
| Launch Task Blueprint (Async) | `POST /task_blueprints/{blueprintId}/launch_async` | ❌ |

## Tasks

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Tasks (Account) | `GET /tasks` | ✅ reader `tasks.list` |
| Get Tasks (Folder) | `GET /folders/{folderId}/tasks` | ✅ reader `tasks.list` (folder/project scope) |
| Get Tasks (Space) | `GET /spaces/{spaceId}/tasks` | ✅ reader `tasks.list` (space scope) |
| Get Tasks By IDs | `GET /tasks/{taskIds}` | ✅ reader `tasks.get` |
| Query Tasks Fields History | `GET /tasks/{taskIds}/tasks_history` | ✅ reader `tasks.history` |
| Create Task | `POST /folders/{folderId}/tasks` | ✅ writer `tasks.create` |
| Update Task | `PUT /tasks/{taskId}` | ✅ writer `tasks.update` |
| Update Tasks (Bulk) | `PUT /tasks/{taskIds}` | ❌ |
| Delete Task | `DELETE /tasks/{taskId}` | ✅ admin `tasks.delete` |

## Timelog Categories

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Timelog Categories | `GET /timelog_categories` | ❌ |

## Timelog Locks

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Timelog Locks (Folder) | `GET /folders/{folderId}/timelog_lock_periods` | ❌ |
| Create Timelog Lock (Folder) | `POST /folders/{folderId}/timelog_lock_periods` | ❌ |
| Delete Timelog Lock (Folder) | `DELETE /folders/{folderId}/timelog_lock_periods` | ❌ |
| Get Timelog Locks (Task) | `GET /tasks/{taskId}/timelog_lock_periods` | ❌ |
| Get Timelog Locks (Space) | `GET /spaces/{spaceId}/timelog_lock_periods` | ❌ |
| Create Timelog Lock (Space) | `POST /spaces/{spaceId}/timelog_lock_periods` | ❌ |
| Delete Timelog Lock (Space) | `DELETE /spaces/{spaceId}/timelog_lock_periods` | ❌ |

## Timelogs

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Timelogs (Account) | `GET /timelogs` | ✅ reader `timelogs.list` |
| Get Timelogs (User) | `GET /contacts/{contactId}/timelogs` | ✅ reader `timelogs.list` (user scope) |
| Get Timelogs (Folder) | `GET /folders/{folderId}/timelogs` | ✅ reader `timelogs.list` (folder/project scope) |
| Get Timelogs (Task) | `GET /tasks/{taskId}/timelogs` | ✅ reader `timelogs.list` (task scope) |
| Get Timelogs (Category) | `GET /timelog_categories/{categoryId}/timelogs` | ✅ reader `timelogs.list` (category scope) |
| Get Timelogs By ID | `GET /timelogs/{timelogIds}` | ✅ reader `timelogs.get` |
| Create Timelog | `POST /tasks/{taskId}/timelogs` | ✅ writer `timelogs.create` |
| Modify Timelog | `PUT /timelogs/{timelogId}` | ✅ writer `timelogs.update` |
| Delete Timelog | `DELETE /timelogs/{timelogId}` | ✅ admin `timelogs.delete` |

## Timesheets & Submission Rules

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Timesheets | `GET /timesheets` | ❌ |
| Create Timesheet | `POST /timesheets` | ❌ |
| Update Timesheet | `PUT /timesheets/{timesheetId}` | ❌ |
| Update Timesheet Row | `PUT /timesheet_rows/{rowId}` | ❌ |
| Get Timesheet Submission Rules (Account) | `GET /timesheet_submission_rules` | ❌ |
| Get Timesheet Submission Rules (Work Schedule) | `GET /workschedules/{scheduleId}/timesheet_submission_rules` | ❌ |
| Update Timesheet Submission Rules | `PUT /workschedules/{scheduleId}/timesheet_submission_rules` | ❌ |

## User Schedules

| Operation | Method and path | Status |
| --- | --- | --- |
| Get Work Schedule Capacity Changes (User) | `GET /user_schedule_capacity_change` | ❌ |
| Get User Schedule Capacity Change By ID | `GET /user_schedule_capacity_change/{ids}` | ❌ |
| Create User Schedule Capacity Change | `POST /users/{userId}/user_schedule_capacity_change` | ❌ |
| Update User Schedule Capacity Change | `PUT /user_schedule_capacity_change/{id}` | ❌ |
| Delete User Schedule Capacity Change | `DELETE /user_schedule_capacity_change/{id}` | ❌ |
| Query User Schedule Exceptions | `GET /user_schedule_exclusions` | ❌ |
| Get User Schedule Exception By ID | `GET /user_schedule_exclusions/{id}` | ❌ |
| Create User Schedule Exception | `POST /user_schedule_exclusions` | ❌ |
| Update User Schedule Exception | `PUT /user_schedule_exclusions/{id}` | ❌ |
| Delete User Schedule Exception | `DELETE /user_schedule_exclusions/{id}` | ❌ |
| Query User Schedule Partial Exceptions | `GET /user_schedule_partial_exclusion` | ❌ |
| Get User Schedule Partial Exceptions By ID | `GET /user_schedule_partial_exclusion/{ids}` | ❌ |
| Create User Schedule Partial Exception | `POST /user_schedule_partial_exclusion` | ❌ |
| Update User Schedule Partial Exception | `PUT /user_schedule_partial_exclusion/{id}` | ❌ |
| Delete User Schedule Partial Exception | `DELETE /user_schedule_partial_exclusion/{id}` | ❌ |

## User Types

| Operation | Method and path | Status |
| --- | --- | --- |
| Get User Types | `GET /user_types` | ✅ reader `users.types.list` |

## Users

| Operation | Method and path | Status |
| --- | --- | --- |
| Query User | `GET /users/{userId}` | ✅ reader `users.get` |
| Modify User | `PUT /users/{userId}` | ✅ writer `users.update` |
| Modify Users (Bulk activate/deactivate) | `PUT /users/{userIds}` | ❌ |

## Version

| Operation | Method and path | Status |
| --- | --- | --- |
| API Version | `GET /version` | ❌ |

## Webhooks

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Webhooks | `GET /webhooks` | ✅ reader `webhooks.list` |
| Get Webhook By ID | `GET /webhooks/{webhookId}` | ✅ reader `webhooks.get` |
| Create Webhook | `POST /webhooks`, `/folders/{id}/webhooks`, `/spaces/{id}/webhooks` | ✅ writer `webhooks.create` (account/folder/project/space scope) |
| Modify Webhook | `PUT /webhooks/{webhookId}` | ✅ writer `webhooks.update` |
| Delete Webhook | `DELETE /webhooks/{webhookId}` | ✅ admin `webhooks.delete` |

## Work Schedules

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Work Schedules (All) | `GET /workschedules` | ❌ |
| Query Work Schedule (Single) | `GET /workschedules/{scheduleId}` | ❌ |
| Create Work Schedule | `POST /workschedules` | ❌ |
| Update Work Schedule | `PUT /workschedules/{scheduleId}` | ❌ |
| Delete Work Schedule | `DELETE /workschedules/{scheduleId}` | ❌ |
| Copy Work Schedule | `POST /workschedules/{scheduleId}/duplicate` | ❌ |
| Get Capacity Changes (Work Schedule) | `GET /workschedules/{scheduleId}/workschedule_capacity_change` | ❌ |
| Get Capacity Changes By ID | `GET /workschedule_capacity_change/{ids}` | ❌ |
| Create Capacity Change | `POST /workschedules/{scheduleId}/workschedule_capacity_change` | ❌ |
| Update Capacity Change | `PUT /workschedule_capacity_change/{id}` | ❌ |
| Delete Capacity Change | `DELETE /workschedule_capacity_change/{id}` | ❌ |
| Get Exceptions (Work Schedule) | `GET /workschedules/{scheduleId}/workschedule_exclusions` | ❌ |
| Get Exception By ID | `GET /workschedule_exclusions/{id}` | ❌ |
| Create Exception | `POST /workschedules/{scheduleId}/workschedule_exclusions` | ❌ |
| Update Exception | `PUT /workschedule_exclusions/{id}` | ❌ |
| Delete Exception | `DELETE /workschedule_exclusions/{id}` | ❌ |

## Workflows

| Operation | Method and path | Status |
| --- | --- | --- |
| Query Workflows (Account) | `GET /workflows` | ✅ reader `workflows.list` |
| Query Workflows (Space) | `GET /spaces/{spaceId}/workflows` | ❌ |
| Create Workflow | `POST /workflows` | ✅ writer `workflows.create` |
| Modify Workflow | `PUT /workflows/{workflowId}` | ✅ writer `workflows.update` |

## Known upstream absences

Documented in `design-capability-matrix.md` and unchanged: Wrike API v4 has no
single-workflow GET (`workflows.get`) and no paginated user list
(`users.list`), so neither is a coverage gap.

## Out of scope: separate Wrike API families

Entirely unimplemented. These are not part of the API v4 REST surface and
would need their own transport/auth review before adoption.

| Family | Operations |
| --- | --- |
| Databases (table-based API) | list/create/get/update/delete databases; folder databases; fields (create/get/update/delete); records (list/create/update/delete, single record) |
| Folder resources (table-based API) | folders by ids, create, get, update, delete, subfolders, root folder |
| Tags | search tags |
| DAM (Digital Asset Management) | attributes, uploads, asset search/metadata, download/thumbnail/view URLs, folder metadata/items/roots |

## Parameter-level coverage

This file tracks operations, not arguments. Individual capabilities may still
accept fewer filters than the upstream endpoint documents (the `updatedDate`
filter on `tasks.list` / `comments.list` was such a gap). Argument-level gaps
are tracked per capability in the source definitions and should be closed
alongside the section that owns them.
