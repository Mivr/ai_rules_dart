public struct BigUInt: CustomStringConvertible {
  public let description: String

  public init(_ value: Int) {
    self.description = "\(value)"
  }

  public init(_ description: String) {
    self.description = description
  }

  public func power(_ exponent: Int) -> BigUInt {
    return BigUInt("0")
  }
}

public struct BigInt: CustomStringConvertible {
  public let description: String

  public init?(_ description: String, radix: Int = 10) {
    self.description = "0"
  }
}
