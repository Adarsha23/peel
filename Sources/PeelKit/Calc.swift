import Foundation

/// Tiny arithmetic evaluator behind inline "240*1.18=" math.
/// Deliberately not NSExpression — that raises uncatchable ObjC exceptions on
/// malformed input, and users type malformed input all day.
public enum Calc {
    public static func evaluate(_ input: String) -> Double? {
        var parser = Parser(input)
        guard let value = parser.expression(), parser.atEnd else { return nil }
        return value.isFinite ? value : nil
    }

    /// Formatted like a human wrote it: 60, not 60.0; 283.2, not 283.1999999.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0

        init(_ s: String) {
            chars = Array(s.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/"))
        }

        var atEnd: Bool { peek() == nil }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                pos += 1
                guard let right = term() else { return nil }
                left = (op == "+") ? left + right : left - right
            }
            return left
        }

        mutating func term() -> Double? {
            guard var left = factor() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                pos += 1
                guard let right = factor() else { return nil }
                if op == "/" {
                    guard right != 0 else { return nil }
                    left /= right
                } else {
                    left *= right
                }
            }
            return left
        }

        mutating func factor() -> Double? {
            skipSpaces()
            if peek() == "(" {
                pos += 1
                let value = expression()
                skipSpaces()
                guard peek() == ")" else { return nil }
                pos += 1
                skipSpaces()
                return value
            }
            if peek() == "-" {
                pos += 1
                return factor().map { -$0 }
            }
            var digits = ""
            while let c = peek(), c.isNumber || c == "." {
                digits.append(c)
                pos += 1
            }
            skipSpaces()
            guard !digits.isEmpty else { return nil }
            return Double(digits)
        }

        mutating func skipSpaces() {
            while peek() == " " { pos += 1 }
        }

        func peek() -> Character? {
            pos < chars.count ? chars[pos] : nil
        }
    }
}
