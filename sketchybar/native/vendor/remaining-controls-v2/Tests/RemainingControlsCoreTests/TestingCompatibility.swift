import Foundation

final class SelfTestRecorder {
    static var failures = 0
    static var assertions = 0

    static func check(_ condition: Bool) {
        assertions += 1
        if !condition {
            failures += 1
            print("FAIL assertion")
        }
    }
}

func XCTAssertTrue(_ value: @autoclosure () -> Bool) {
    SelfTestRecorder.check(value())
}

func XCTAssertFalse(_ value: @autoclosure () -> Bool) {
    SelfTestRecorder.check(!value())
}

func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T) {
    SelfTestRecorder.check(lhs() == rhs())
}

func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T) {
    SelfTestRecorder.check(lhs() != rhs())
}

func XCTAssertNil<T>(_ value: @autoclosure () -> T?) {
    SelfTestRecorder.check(value() == nil)
}

func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?) {
    SelfTestRecorder.check(value() != nil)
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T) {
    SelfTestRecorder.check(lhs() >= rhs())
}
