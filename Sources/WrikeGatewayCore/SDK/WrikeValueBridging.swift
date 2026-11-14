import GatewaySDKKit

extension GatewayJSONValue {
  public init(_ value: WrikeValue) {
    switch value {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .int(let value): self = .int(value)
    case .double(let value): self = .double(value)
    case .string(let value): self = .string(value)
    case .array(let value): self = .array(value.map(GatewayJSONValue.init))
    case .object(let value): self = .object(value.mapValues(GatewayJSONValue.init))
    }
  }
}

extension WrikeValue {
  public init(_ value: GatewayJSONValue) {
    switch value {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .int(let value): self = .int(value)
    case .double(let value): self = .double(value)
    case .string(let value): self = .string(value)
    case .array(let value): self = .array(value.map(WrikeValue.init))
    case .object(let value): self = .object(value.mapValues(WrikeValue.init))
    }
  }
}
