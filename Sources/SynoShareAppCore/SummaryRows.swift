import Foundation
import SynoShareKit

/// One labelled figure in the Summary sheet.
public struct SummaryRow: Sendable, Equatable {
    public let title: String
    public let value: String
}

/// Turns a `Report` into the Summary sheet's rows.
public enum SummaryRows {
    public static func rows(for report: Report) -> [SummaryRow] {
        let done = report.count(.done)
        let adopted = report.count(.adopted)
        let conflicts = report.count(.conflict) + report.count(.changedOnServer)
        return [
            SummaryRow(title: "Folders discovered",
                       value: "\(report.folders)" + (report.listingComplete ? "" : " (listing incomplete)")),
            SummaryRow(title: "Files discovered", value: "\(report.files)"),
            SummaryRow(title: "Expected size", value: Formatting.bytes(report.expectedBytes)),
            SummaryRow(title: "Expected on disk (exFAT)", value: Formatting.bytes(report.expectedOnDiskBytes)),
            SummaryRow(title: "Done", value: adopted > 0 ? "\(done + adopted) (\(adopted) adopted, size-only)" : "\(done)"),
            SummaryRow(title: "Pending", value: "\(report.count(.pending) + report.count(.downloading))"),
            SummaryRow(title: "Failed", value: "\(report.count(.failed))"),
            SummaryRow(title: "Skipped (unsafe names)", value: "\(report.count(.skippedUnsafe))"),
            SummaryRow(title: "Conflicts", value: "\(conflicts)"),
            SummaryRow(title: "Downloaded", value: Formatting.bytes(report.completedBytes)),
            SummaryRow(title: "Size mismatches", value: "\(report.sizeMismatches)"),
            SummaryRow(title: "Renamed", value: "\(report.renamed.count)"),
        ]
    }
}
