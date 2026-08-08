import Foundation

final class PrototypeTestState: @unchecked Sendable {
    static let shared = PrototypeTestState()
    private let lock = NSLock()
    private(set) var failures = 0

    func record(_ message: String) {
        lock.lock()
        failures += 1
        lock.unlock()
        FileHandle.standardError.write(Data(("TEST_FAILURE " + message + "\n").utf8))
    }
}

func XCTAssertTrue(_ value: @autoclosure () -> Bool) {
    if !value() { PrototypeTestState.shared.record("expected true") }
}

func XCTAssertFalse(_ value: @autoclosure () -> Bool) {
    if value() { PrototypeTestState.shared.record("expected false") }
}

func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T,
                                  _ rhs: @autoclosure () -> T) {
    if lhs() != rhs() { PrototypeTestState.shared.record("values differ") }
}

func XCTAssertEqual(_ lhs: @autoclosure () -> Double,
                    _ rhs: @autoclosure () -> Double,
                    accuracy: Double) {
    if abs(lhs() - rhs()) > accuracy { PrototypeTestState.shared.record("values differ beyond accuracy") }
}

func XCTAssertNil<T>(_ value: @autoclosure () -> T?) {
    if value() != nil { PrototypeTestState.shared.record("expected nil") }
}

func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?) {
    if value() == nil { PrototypeTestState.shared.record("expected non-nil") }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do {
        _ = try expression()
        PrototypeTestState.shared.record("expected error")
    } catch {
        // Expected.
    }
}
