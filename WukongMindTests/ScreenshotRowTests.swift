import XCTest
import UIKit
@testable import WukongMind

final class ScreenshotRowTests: XCTestCase {
    private func row(images: [AgentImage] = [], running: Bool = false, error: Bool = false,
                     warning: Bool = false) -> BrowserAgentToolCallRow {
        var r = BrowserAgentToolCallRow(callID: "c", runID: UUID(), stepNumber: 2, toolName: "screenshot",
                                        argumentSummary: "", argumentsJSON: "{}", isRunning: running, isError: error)
        r.images = images
        if warning {
            r.pageFeedback = PageFeedbackReport(
                before: snap, after: snap, reasons: ["text shrank"])
        }
        return r
    }

    private let snap = PageStateSnapshot(url: "https://x.test", textLength: 1, documentHeight: 1, isScrollable: false,
                                         linkCount: 0, formControlCount: 0, visibleImageCount: 0, pageErrorCount: 0)

    private func jpeg() -> AgentImage {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        return AgentImage(data: img.jpegData(compressionQuality: 0.5)!.base64EncodedString())
    }

    func testRowsCarryImagesOnlyWhenFinishedWithImages() {
        XCTAssertTrue(row(images: [jpeg()]).carriesImages)
        XCTAssertFalse(row().carriesImages)
        XCTAssertFalse(row(images: [jpeg()], running: true).carriesImages)
    }

    func testThumbnailIsDownsampled() async throws {
        let thumb = await AgentImageLoader.thumbnail(jpeg(), maxPixel: 20)
        XCTAssertNotNil(thumb)
        XCTAssertLessThanOrEqual(max(thumb!.size.width, thumb!.size.height), 20)
    }

    func testMissingOrCorruptImageGivesNilNotCrash() async {
        let empty = await AgentImageLoader.thumbnail(AgentImage(data: ""), maxPixel: 20)
        let corrupt = await AgentImageLoader.full(AgentImage(data: "bm90IGFuIGltYWdl"))
        let bad64 = await AgentImageLoader.thumbnail(AgentImage(data: "%%%"), maxPixel: 20)
        XCTAssertNil(empty); XCTAssertNil(corrupt); XCTAssertNil(bad64)
    }

    func testPageWarningIsNotAnError() {
        let warning = row(warning: true)
        XCTAssertTrue(warning.isPageWarning)
        XCTAssertFalse(warning.isError)
        XCTAssertFalse(row(error: true, warning: true).isPageWarning, "A real error keeps the error look.")
        XCTAssertFalse(row().isPageWarning)
    }
}
