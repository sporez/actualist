import Foundation

enum ReportArithmetic {
    static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return result.partialValue
    }

    static func subtract(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return result.partialValue
    }

    static func sum<S: Sequence>(_ values: S) throws -> Int where S.Element == Int {
        var total = 0
        for value in values {
            total = try add(total, value)
        }
        return total
    }

    static func scaled(_ value: Int, multiplier: Int, divisor: Int) throws -> Int {
        guard divisor > 0 else {
            throw LocalFirstError.numericValueOutOfRange
        }
        let multiplied = value.multipliedReportingOverflow(by: multiplier)
        guard !multiplied.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }

        let quotient = multiplied.partialValue / divisor
        let remainder = multiplied.partialValue % divisor
        let doubledRemainder = remainder.multipliedReportingOverflow(by: 2)
        guard !doubledRemainder.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        guard doubledRemainder.partialValue.magnitude >= divisor.magnitude else {
            return quotient
        }
        return try add(quotient, multiplied.partialValue >= 0 ? 1 : -1)
    }
}
