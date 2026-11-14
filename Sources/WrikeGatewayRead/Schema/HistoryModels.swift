import WrikeGatewayCore

/// Shapes shared by the three Wrike field-history operations.
///
/// The official reference documents `GET /contacts/{contactIds}/contacts_history`,
/// `GET /folders/{folderIds}/folders_history`, and
/// `GET /tasks/{taskIds}/tasks_history` with one common filter pair, an
/// `updatedDate` instant range and a `fields` selection, and two history-item
/// shapes: `BudgetMetricHistoryItem` for the budget metrics and
/// `BudgetRateHistoryItem` for contact rates. Declaring them once here is what
/// keeps the three registrations from drifting apart.
///
/// Each history operation addresses several entities through one
/// comma-separated path segment, which is why the identifier argument binds an
/// `[ID!]` list to a single `{...Ids}` placeholder rather than one id.
public enum HistoryModels {
  /// One value of a budget metric and the window during which it applied.
  ///
  /// `value` and `startDate` are documented as required; a history item without
  /// them describes no window at all, so their absence is an upstream contract
  /// violation rather than a null field.
  public static let budgetMetricItem = ModelShape(
    typeName: "BudgetMetricHistoryItem",
    fields: [
      ModelField("value", .number, required: true),
      ModelField("startDate", .dateTime, required: true),
      ModelField("endDate", .dateTime)
    ]
  )

  /// One bill or cost rate, the window during which it applied, and where the
  /// rate came from. The reference marks no field of this item as required, so
  /// none is required here either.
  public static let rateItem = ModelShape(
    typeName: "BudgetRateHistoryItem",
    fields: [
      ModelField("rateValue", .number),
      ModelField("startDate", .dateTime),
      ModelField("endDate", .dateTime),
      ModelField("rateSource", .string)
    ]
  )

  /// The `updatedDate` filter. Wrike takes it as a JSON object in a single
  /// query parameter, which is what the `.queryJSON` binding encodes. The
  /// `.bodyJSON` binding on each field names the upstream JSON key.
  public static let instantRange = InputObjectShape(
    typeName: "InstantRangeInput",
    fields: [
      ArgumentDefinition("start", .string, .bodyJSON("start")),
      ArgumentDefinition("end", .string, .bodyJSON("end"))
    ]
  )

  /// The official reference bounds each `{...Ids}` path segment at 1000
  /// entries. Enforcing it locally keeps an over-long URL from being assembled
  /// at all instead of sending a request Wrike will refuse.
  public static let maximumIdentifiers = 1000

  /// The identifier list every field-history operation addresses.
  public static func identifierArgument(
    placeholder: String
  ) -> ArgumentDefinition {
    ArgumentDefinition(
      "ids",
      .identifierList,
      .path(placeholder),
      required: true,
      maximumCount: maximumIdentifiers
    )
  }

  /// The two filters every field-history operation accepts. The accepted
  /// `fields` values differ per resource, so each registration supplies its own
  /// curated enumeration rather than sharing one list.
  public static func filterArguments(
    fieldEnum name: String,
    values: [String]
  ) -> [ArgumentDefinition] {
    [
      ArgumentDefinition("updatedDate", .inputObject(instantRange), .queryJSON("updatedDate")),
      ArgumentDefinition("fields", .enumerationList(name, values), .queryList("fields"))
    ]
  }
}
