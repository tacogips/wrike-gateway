import GatewaySDKKit
import Testing
@testable import WrikeGatewayCore

@Suite("Wrike schema catalog exporter")
struct WrikeSchemaCatalogExporterTests {
  @Test("Catalog filters tier and constructs structural required types")
  func filtersAndValidates() {
    let shape = ModelShape(typeName: "Thing", fields: [ModelField("id", .identifier, required: true)])
    let definition = CapabilityDefinition(
      id: CapabilityID("things.get"),
      field: "thing",
      tier: .reader,
      operationClass: .read,
      method: .get,
      pathTemplate: "/things/{id}",
      arguments: [ArgumentDefinition("id", .identifierList, .path("id"), required: true)],
      result: .single(shape),
      scopes: .workspaceRead,
      summary: "Gets a thing."
    )
    let catalog = GatewaySchemaCatalog.wrike(tier: .reader, definitions: [definition])
    #expect(catalog.validate().isEmpty)
    #expect(catalog.operation(named: "thing")?.arguments.first?.type.graphQLString == "[ID!]!")
    #expect(catalog.namedType("Thing")?.objectFields?.first?.type.graphQLString == "ID!")
    #expect(catalog.namedType("PageInfo") != nil)
  }

  @Test("Exporter emits recursive inputs and conditional helper types")
  func conditionalTypes() {
    let task = ModelShape(typeName: "Task", fields: [ModelField("id", .identifier, required: true)])
    let input = InputObjectShape(typeName: "CreateThingInput", fields: [
      ArgumentDefinition("state", .enumeration("ThingState", ["Open", "Closed"]), .bodyJSON("state"), required: true)
    ])
    let create = CapabilityDefinition(
      id: CapabilityID("things.create"), field: "createThing", tier: .writer,
      operationClass: .create, method: .post, pathTemplate: "/things",
      arguments: [
        ArgumentDefinition("scope", .scope, .scope),
        ArgumentDefinition("page", .page, .page),
        ArgumentDefinition("input", .inputObject(input), .container, required: true)
      ],
      result: .payload(field: "thing", task), scopes: .workspaceReadWrite,
      summary: "Creates a thing."
    )
    let delete = CapabilityDefinition(
      id: CapabilityID("things.delete"), field: "deleteThing", tier: .admin,
      operationClass: .delete, method: .delete, pathTemplate: "/things/{id}",
      arguments: [ArgumentDefinition("id", .identifier, .path("id"), required: true)],
      result: .deletion, scopes: .workspaceReadWrite, summary: "Deletes a thing."
    )
    let catalog = GatewaySchemaCatalog.wrike(tier: .admin, definitions: [delete, create])
    #expect(catalog.validate().isEmpty)
    #expect(catalog.namedType("ThingState")?.enumValues == ["Open", "Closed"])
    #expect(catalog.namedType("CreateThingInput")?.inputFields?.first?.type.graphQLString == "ThingState!")
    #expect(catalog.namedType("PageInput") != nil)
    #expect(catalog.namedType("ScopeInput") != nil)
    #expect(catalog.namedType("DeletionPayload") != nil)
    #expect(catalog.namedType("TaskPayload") != nil)
  }

  @Test("Exporter covers structural argument and result families deterministically")
  func structuralCoverageMatrix() throws {
    let child = ModelShape(typeName: "Child", fields: [ModelField("name", .string, required: true)])
    let thing = ModelShape(typeName: "Thing", fields: [
      ModelField("id", .identifier, required: true),
      ModelField("child", .object(child)),
      ModelField("children", .objectList(child))
    ])
    let nestedInput = InputObjectShape(typeName: "NestedInput", fields: [
      ArgumentDefinition("enabled", .boolean, .bodyJSON("enabled"))
    ])
    let input = InputObjectShape(typeName: "ThingInput", fields: [
      ArgumentDefinition("nested", .inputObject(nestedInput), .container),
      ArgumentDefinition("weight", .number, .bodyJSON("weight"))
    ])
    let arguments: [ArgumentDefinition] = [
      ArgumentDefinition("ids", .identifierList, .queryList("ids"), required: true),
      ArgumentDefinition("id", .identifier, .query("id")),
      ArgumentDefinition("text", .string, .query("text")),
      ArgumentDefinition("texts", .stringList, .queryList("texts")),
      ArgumentDefinition("count", .integer, .query("count")),
      ArgumentDefinition("ratio", .number, .query("ratio")),
      ArgumentDefinition("enabled", .boolean, .query("enabled")),
      ArgumentDefinition("scope", .scope, .scope),
      ArgumentDefinition("page", .page, .page),
      ArgumentDefinition("state", .enumeration("ThingState", ["Open", "Closed"]), .query("state")),
      ArgumentDefinition("states", .enumerationList("ThingState", ["Open", "Closed"]), .queryList("states")),
      ArgumentDefinition("input", .inputObject(input), .container)
    ]
    func definition(_ field: String, _ result: ResultShape) -> CapabilityDefinition {
      CapabilityDefinition(
        id: CapabilityID("things.\(field)"), field: field, tier: .reader,
        operationClass: .read, method: .get, pathTemplate: "/things",
        arguments: arguments, result: result, scopes: .workspaceRead, summary: "Tests \(field)."
      )
    }

    let catalog = GatewaySchemaCatalog.wrike(tier: .reader, definitions: [
      definition("singleThing", .single(thing)),
      definition("thingConnection", .connection(thing)),
      definition("thingList", .list(thing)),
      definition("thingPayload", .payload(field: "thing", thing)),
      definition("deleteThing", .deletion),
      definition("downloadThing", .fileOutput(FileOutputShape.shape))
    ])

    #expect(catalog.validate().isEmpty)
    #expect(Set(catalog.types.map(\.name)).count == catalog.types.count)
    #expect(catalog.namedType("Child") != nil)
    #expect(catalog.namedType("NestedInput") != nil)
    #expect(catalog.namedType("ThingInput") != nil)
    #expect(catalog.namedType("ThingState")?.enumValues == ["Open", "Closed"])
    #expect(catalog.namedType("PageInput") != nil)
    #expect(catalog.namedType("ScopeInput") != nil)
    #expect(catalog.namedType("ThingConnection") != nil)
    #expect(catalog.namedType("ThingPayload") != nil)
    #expect(catalog.namedType("DeletionPayload") != nil)
    #expect(catalog.namedType("DownloadedFile") != nil)
    let single = try #require(catalog.operation(named: "singleThing"))
    #expect(single.arguments.first(where: { $0.name == "ids" })?.type.graphQLString == "[ID!]!")
    #expect(single.arguments.first(where: { $0.name == "id" })?.type.graphQLString == "ID")
    #expect(single.arguments.first(where: { $0.name == "states" })?.type.graphQLString == "[ThingState!]")
    let document = try GatewayDocumentBuilder(catalog: catalog).build(
      GatewayOperationRequest(operation: "singleThing", variables: ["ids": .array([.string("IEAAAAAAKQAB5FNY")])])
    )
    #expect(document.document.contains("$ids: [ID!]!"))
  }
}
