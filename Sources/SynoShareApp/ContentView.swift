import SwiftUI
import SynoShareAppCore

struct ContentView: View {
    @Bindable var model: DownloadViewModel

    var body: some View {
        Form {
            ConnectionSection(model: model)
            ActionsSection(model: model)
            ProgressSection(model: model)
            IssuesSection(model: model)
        }
        .formStyle(.grouped)
        .task { await model.start() }
        .sheet(isPresented: $model.isSummaryPresented) {
            SummaryView(model: model)
        }
    }
}

/// An error shown directly under the control it concerns, with what to do next.
struct FieldErrorView: View {
    let advice: ErrorAdvice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(advice.message).foregroundStyle(.primary)
                Text(advice.recovery).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(advice.message) \(advice.recovery)")
    }
}
