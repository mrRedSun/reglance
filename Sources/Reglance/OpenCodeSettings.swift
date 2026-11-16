import ChatCore
import SwiftUI

/// Which OpenCode models the picker offers. OpenCode lists every model of every signed-in
/// provider (often over a hundred), so the person turns on the few they use.
struct OpenCodeModelSettings: View {
    @State private var available: [ModelOption]?
    @State private var enabled = Set(OpenCodeBackend.enabledModels)
    @State private var search = ""

    var body: some View {
        Group {
            if let available, !available.isEmpty {
                DisclosureGroup {
                    TextField("Search models", text: $search)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(groups(available), id: \.provider) { group in
                                Text(group.provider)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 6)
                                ForEach(group.models) { option in
                                    Toggle(option.name, isOn: binding(for: option.model.id))
                                        .help(option.model.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                } label: {
                    LabeledContent("Models in the picker", value: enabled.isEmpty ? "None" : "\(enabled.count)")
                }
                Text("OpenCode offers every model of the providers you signed in to. Turn on the ones you want in the model picker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if available == nil {
                LabeledContent("Models") { ProgressView().controlSize(.small) }
            }
        }
        .task {
            available = await OpenCodeBackend.availableModels() ?? []
        }
    }

    private func groups(_ options: [ModelOption]) -> [(provider: String, models: [ModelOption])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty ? options : options.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.model.id.localizedCaseInsensitiveContains(query)
        }
        return Dictionary(grouping: matches, by: \.detail)
            .map { (provider: $0.key, models: $0.value) }
            .sorted { $0.provider < $1.provider }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(id) },
            set: { isOn in
                if isOn { enabled.insert(id) } else { enabled.remove(id) }
                OpenCodeBackend.enabledModels = (available ?? []).map(\.model.id).filter(enabled.contains)
                Task { await ModelLibrary.shared.refresh([.opencode], force: true) }
            }
        )
    }
}
