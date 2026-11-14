import WrikeGatewayCore
import WrikeGatewayRead

/// Writer capabilities for contacts, users, groups, and the account.
///
/// Every operation here is POST- or PUT-backed. Membership changes name the
/// relationship explicitly and expose no recursive or wildcard removal, and no
/// DELETE-backed operation exists in this module.
public enum PeopleMutations {
  public static let updateContact = CapabilityDefinition(
    id: CapabilityID("contacts.update"),
    field: "updateContact",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/contacts/{contactId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateContactInput",
          fields: [
            ArgumentDefinition("contactId", .identifier, .path("contactId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title")),
            ArgumentDefinition("companyName", .string, .bodyForm("companyName")),
            ArgumentDefinition("phone", .string, .bodyForm("phone")),
            ArgumentDefinition("location", .string, .bodyForm("location")),
            ArgumentDefinition("jobRoleId", .identifier, .bodyForm("jobRoleId"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "contact", ContactModels.contact),
    scopes: .workspaceReadWrite,
    summary: "Updates one contact's profile fields."
  )

  public static let updateUser = CapabilityDefinition(
    id: CapabilityID("users.update"),
    field: "updateUser",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/users/{userId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateUserInput",
          fields: [
            ArgumentDefinition("userId", .identifier, .path("userId"), required: true),
            ArgumentDefinition(
              "role",
              .enumeration("UserRole", ["User", "Collaborator"]),
              .bodyForm("profile")
            ),
            ArgumentDefinition("external", .boolean, .bodyForm("external"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "user", UserCapabilities.user),
    scopes: ScopeRequirement(accepted: ["amReadWriteUser"], recommended: "amReadWriteUser"),
    summary: "Updates one user's account role."
  )

  public static let createGroup = CapabilityDefinition(
    id: CapabilityID("groups.create"),
    field: "createGroup",
    tier: .writer,
    operationClass: .create,
    method: .post,
    pathTemplate: "/groups",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "CreateGroupInput",
          fields: [
            ArgumentDefinition("title", .string, .bodyForm("title"), required: true),
            ArgumentDefinition("memberIds", .identifierList, .bodyForm("members")),
            ArgumentDefinition("parentId", .identifier, .bodyForm("parentId"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "group", GroupCapabilities.group),
    scopes: .accountGroupReadWrite,
    summary: "Creates a user group with an explicit member list."
  )

  public static let updateGroup = CapabilityDefinition(
    id: CapabilityID("groups.update"),
    field: "updateGroup",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/groups/{groupId}",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateGroupInput",
          fields: [
            ArgumentDefinition("groupId", .identifier, .path("groupId"), required: true),
            ArgumentDefinition("title", .string, .bodyForm("title")),
            // Membership changes name each member explicitly. There is no
            // wildcard, recursive, or "remove all" form.
            ArgumentDefinition("addMemberIds", .identifierList, .bodyForm("addMembers")),
            ArgumentDefinition("removeMemberIds", .identifierList, .bodyForm("removeMembers"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "group", GroupCapabilities.group),
    scopes: .accountGroupReadWrite,
    summary: "Updates a user group's title or named membership."
  )

  public static let updateAccount = CapabilityDefinition(
    id: CapabilityID("account.update"),
    field: "updateAccount",
    tier: .writer,
    operationClass: .update,
    method: .put,
    pathTemplate: "/account",
    arguments: [
      ArgumentDefinition(
        "input",
        .inputObject(InputObjectShape(
          typeName: "UpdateAccountInput",
          fields: [
            ArgumentDefinition("metadata", .string, .bodyForm("metadata"))
          ]
        )),
        .container,
        required: true
      )
    ],
    result: .payload(field: "account", AccountCapabilities.account),
    scopes: .workspaceReadWrite,
    summary: "Updates account-level metadata."
  )

  public static let all: [CapabilityDefinition] = [
    updateContact,
    updateUser,
    createGroup,
    updateGroup,
    updateAccount
  ]
}
