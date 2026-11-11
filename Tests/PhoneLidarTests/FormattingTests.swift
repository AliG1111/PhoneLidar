import XCTest

final class UnitsTests: XCTestCase {
    func testFeetInchesExactValues() {
        XCTAssertEqual(Units.feetInches(0), "0' 0.0\"")
        XCTAssertEqual(Units.feetInches(0.0254), "0' 1.0\"")
        XCTAssertEqual(Units.feetInches(0.3048), "1' 0.0\"")
        XCTAssertEqual(Units.feetInches(2.4384), "8' 0.0\"")
        XCTAssertEqual(Units.feetInches(3.6576), "12' 0.0\"")
        XCTAssertEqual(Units.feetInches(1.0), "3' 3.4\"")
    }

    func testFeetInchesRoundsToOneDecimalOfAnInch() {
        // 0.30 m = 11.811 in
        XCTAssertEqual(Units.feetInches(0.30), "0' 11.8\"")
        // 1.5 m = 59.055 in = 4 ft 11.055 in
        XCTAssertEqual(Units.feetInches(1.5), "4' 11.1\"")
    }

    func testFeetInchesRoundsUpToTwelveInchesCarriesIntoFeet() {
        // 11.96 in rounds to 12.0 in, which must read 1' 0.0", never 0' 12.0".
        XCTAssertEqual(Units.feetInches(11.96 * 0.0254), "1' 0.0\"")
        // 59.99 in -> 4' 12.0" must carry to 5' 0.0".
        XCTAssertEqual(Units.feetInches(59.99 * 0.0254), "5' 0.0\"")
        // Just below the rounding threshold stays in the lower foot.
        XCTAssertEqual(Units.feetInches(11.94 * 0.0254), "0' 11.9\"")
        XCTAssertEqual(Units.feetInches(59.94 * 0.0254), "4' 11.9\"")
    }

    func testFeetInchesNeverShowsTwelveInches() {
        var meters = 0.0
        while meters < 5 {
            let text = Units.feetInches(meters)
            XCTAssertFalse(text.hasSuffix(" 12.0\""), "\(meters) m formatted as \(text)")
            meters += 0.0007
        }
    }

    func testFeetInchesNegativeValuesKeepTheSign() {
        XCTAssertEqual(Units.feetInches(-2.4384), "-8' 0.0\"")
        XCTAssertEqual(Units.feetInches(-0.3), "-0' 11.8\"")
    }

    func testFeetInchesTinyNegativeValueThatRoundsToZeroHasNoSign() {
        // -0.0001 m is 0.004 in: it rounds to 0.0 in and must not read "-0' 0.0"".
        XCTAssertEqual(Units.feetInches(-0.0001), "0' 0.0\"")
        XCTAssertEqual(Units.feetInches(-0.0), "0' 0.0\"")
        // -0.0012 m = 0.047 in still rounds to 0.0; -0.0013 m = 0.051 in rounds to 0.1 and keeps its sign.
        XCTAssertEqual(Units.feetInches(-0.0012), "0' 0.0\"")
        XCTAssertEqual(Units.feetInches(-0.0013), "-0' 0.1\"")
    }

    func testFormatCombinesMetresAndFeetInches() {
        XCTAssertEqual(Units.format(meters: 2.438), "2.438 m  (8' 0.0\")")
        XCTAssertEqual(Units.format(meters: 0), "0.000 m  (0' 0.0\")")
    }

    func testShortUsesTwoDecimals() {
        XCTAssertEqual(Units.short(1.234), "1.23 m")
        XCTAssertEqual(Units.short(0), "0.00 m")
    }

    func testFormatAreaShowsSquareMetresAndSquareFeet() {
        XCTAssertEqual(Units.formatArea(squareMeters: 1), "1.00 m²  (10.8 ft²)")
        XCTAssertEqual(Units.formatArea(squareMeters: 0), "0.00 m²  (0.0 ft²)")
        XCTAssertEqual(Units.formatArea(squareMeters: 20), "20.00 m²  (215.3 ft²)")
    }
}

final class CSVTests: XCTestCase {
    func testEscapeLeavesPlainFieldsAlone() {
        XCTAssertEqual(CSV.escape("wall 1"), "wall 1")
        XCTAssertEqual(CSV.escape(""), "")
        XCTAssertEqual(CSV.escape("12.5"), "12.5")
    }

    func testEscapeQuotesFieldsWithCommas() {
        XCTAssertEqual(CSV.escape("a,b"), "\"a,b\"")
    }

    func testEscapeDoublesEmbeddedQuotes() {
        XCTAssertEqual(CSV.escape("5' 3.0\""), "\"5' 3.0\"\"\"")
        XCTAssertEqual(CSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testEscapeQuotesFieldsWithNewlines() {
        XCTAssertEqual(CSV.escape("line1\nline2"), "\"line1\nline2\"")
    }

    func testMakeJoinsRowsAndEndsWithNewline() {
        XCTAssertEqual(CSV.make([["a", "b"], ["1", "2"]]), "a,b\n1,2\n")
    }

    func testMakeEscapesEachField() {
        XCTAssertEqual(CSV.make([["x,y", "z"]]), "\"x,y\",z\n")
    }

    func testMakeWithNoRowsIsJustANewline() {
        XCTAssertEqual(CSV.make([]), "\n")
    }

    func testMeasurementsHeaderAndRow() {
        let item = PointMeasurement(label: "Door", start: [1, 2, 3], end: [4, 5, 6], meters: 2.4384)
        let lines = CSV.measurements([item]).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)    // header, one row, trailing empty piece
        XCTAssertEqual(String(lines[0]),
                       "label,distance_m,distance_ft_in,start_x_m,start_y_m,start_z_m,end_x_m,end_y_m,end_z_m")
        // The feet-inches text ends in a quote mark, so the field is quoted with the quote doubled.
        XCTAssertEqual(String(lines[1]),
                       "Door,2.4384,\"8' 0.0\"\"\",1.0000,2.0000,3.0000,4.0000,5.0000,6.0000")
    }

    func testMeasurementsEscapesLabelsAndPadsShortCoordinates() {
        let item = PointMeasurement(label: "Roof, north", start: [1], end: [], meters: 0.3048)
        let csv = CSV.measurements([item])
        XCTAssertTrue(csv.contains("\"Roof, north\",0.3048,\"1' 0.0\"\"\",1.0000,0.0000,0.0000,0.0000,0.0000,0.0000\n"), csv)
    }

    func testMeasurementsWithNoItemsIsJustTheHeader() {
        let csv = CSV.measurements([])
        XCTAssertEqual(csv.split(separator: "\n").count, 1)
        XCTAssertTrue(csv.hasPrefix("label,distance_m"))
    }

    func testRoomSummaryIsASeparateBlockWithItsOwnHeader() {
        let rows = CSV.roomSummary(wallCount: 4, wallLengthM: 14.0, wallHeightM: 2.4384, floorAreaM2: 12.5)
        XCTAssertEqual(rows[0], [""])      // empty line before the block
        XCTAssertEqual(rows[1], ["summary_item", "value", "unit"])
        XCTAssertEqual(Array(rows.dropFirst(2)), [
            ["wall_count", "4", "count"],
            ["total_wall_length", "14.0000", "m"],
            ["total_wall_length", Units.feetInches(14.0), "ft_in"],
            ["wall_height_max", "2.4384", "m"],
            ["wall_height_max", "8' 0.0\"", "ft_in"],
            ["floor_area", "12.500", "m2"],
            ["floor_area", "134.55", "ft2"]
        ])
    }

    func testRoomSummaryOmitsWallHeightWhenThereAreNoWalls() {
        let rows = CSV.roomSummary(wallCount: 0, wallLengthM: 0, wallHeightM: 0, floorAreaM2: 0)
        XCTAssertFalse(rows.contains { $0.first == "wall_height_max" })
        XCTAssertEqual(rows.last, ["floor_area", "0.00", "ft2"])
    }

    func testRoomSummaryBlockFollowsTheElementRowsAndEscapesFeetInches() {
        let text = CSV.make([["type", "width_m"], ["wall", "3.0000"]]
            + CSV.roomSummary(wallCount: 1, wallLengthM: 3.0, wallHeightM: 2.4384, floorAreaM2: 9))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "type,width_m")
        XCTAssertEqual(lines[1], "wall,3.0000")
        XCTAssertEqual(lines[2], "")
        XCTAssertEqual(lines[3], "summary_item,value,unit")
        // The feet-and-inches text has a quote, so it is quoted with the quote doubled.
        XCTAssertTrue(lines.contains("wall_height_max,\"8' 0.0\"\"\",ft_in"), text)
        XCTAssertTrue(text.hasSuffix("\n"))
    }
}
