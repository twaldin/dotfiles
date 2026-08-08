import RemainingControlsMacBoundaries

struct BoundaryCompilationTests {
    func testOnlyPublicFrameworkBoundaryTypesAreLinked() {
        XCTAssertNotNil(SealedSystemSettingsBoundary.self)
        XCTAssertNotNil(PublicCoreGraphicsBoundary.self)
    }
}
