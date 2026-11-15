import Foundation
import Testing
@testable import ChatCore

private let chartJSON = #"{"type":"bar","title":"Weight (kg)","y_label":"kg","data":[{"x":"Basenji","y":10,"highlight":true},{"x":"Husky","y":23}]}"#

@Test func splitsCompleteWidgets() {
    let text = """
    Sizes:

    ```chart
    \(chartJSON)
    ```
    A quiz:
    ```html
    <p>Hi</p>
    ```
    ```document
    title: Cheat sheet

    - one
    ```
    Done.
    """
    let segments = ReplySegment.split(text)
    #expect(segments.count == 6)
    #expect(segments[0] == .markdown("Sizes:\n"))
    guard case .chart(let spec) = segments[1] else { Issue.record("no chart"); return }
    #expect(spec.title == "Weight (kg)" && spec.data.count == 2)
    #expect(segments[2] == .markdown("A quiz:"))
    #expect(segments[3] == .html("<p>Hi</p>"))
    #expect(segments[4] == .document(title: "Cheat sheet", body: "- one"))
    #expect(segments[5] == .markdown("Done."))
}

@Test func openFenceMidStreamIsPending() {
    let text = "Here's a chart:\n```chart\n{\"type\":\"bar\",\"da"
    #expect(ReplySegment.split(text, streaming: true) == [.markdown("Here's a chart:"), .pending(.chart)])
    // Cut off for good (e.g. stopped): show the source instead.
    #expect(ReplySegment.split(text) == [.markdown("Here's a chart:"), .markdown("```chart\n{\"type\":\"bar\",\"da\n```")])
}

@Test func holdsBackHalfTypedFence() {
    #expect(ReplySegment.split("Look:\n```cha", streaming: true) == [.markdown("Look:")])
    #expect(ReplySegment.split("Look:\n```chart", streaming: true) == [.markdown("Look:")])
    #expect(ReplySegment.split("Look:\n```chart\n", streaming: true) == [.markdown("Look:"), .pending(.chart)])
}

@Test func malformedChartFallsBackToCode() {
    let text = "```chart\n{\"type\":\"bar\", oops}\n```"
    #expect(ReplySegment.split(text) == [.markdown("```chart\n{\"type\":\"bar\", oops}\n```")])
    let unknownType = "```chart\n{\"type\":\"radar\",\"title\":\"t\",\"data\":[{\"x\":1,\"y\":2}]}\n```"
    guard case .markdown = ReplySegment.split(unknownType).first else { Issue.record("expected code"); return }
}

@Test func widgetFencesInsideOtherCodeAreIgnored() {
    let text = "````markdown\n```chart\n{}\n```\n````\nAfter"
    #expect(ReplySegment.split(text) == [.markdown(text)])
}

@Test func decodesChartSpec() throws {
    let spec = try ChartSpec.decode(chartJSON)
    #expect(spec.type == .bar && spec.yLabel == "kg" && spec.xLabel == nil)
    #expect(spec.data[0] == .init(x: .text("Basenji"), y: 10, series: nil, highlight: true))
    #expect(!spec.hasNumericX && spec.seriesNames.isEmpty)

    let line = try ChartSpec.decode(#"{"type":"line","title":"t","data":[{"x":2020,"y":1.5,"series":"A"},{"x":2021,"y":2,"series":"B"}]}"#)
    #expect(line.hasNumericX && line.seriesNames == ["A", "B"])
    #expect(line.data[0].x == .number(2020) && line.data[0].x.label == "2020")

    let many = (0..<80).map { #"{"x":\#($0),"y":1}"# }.joined(separator: ",")
    #expect(try ChartSpec.decode(#"{"type":"scatter","title":"t","data":[\#(many)]}"#).data.count == 50)
    #expect(throws: (any Error).self) { try ChartSpec.decode(#"{"type":"pie","title":"t","data":[]}"#) }
}

@Test func documentWithoutTitleLine() {
    #expect(ReplySegment.split("```document\n# Notes\n```") == [.document(title: "Document", body: "# Notes")])
}
