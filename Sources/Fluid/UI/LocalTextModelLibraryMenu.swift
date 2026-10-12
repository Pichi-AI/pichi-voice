import SwiftUI

/// A metadata view over the existing model picker, never a model installer.
struct LocalTextModelLibraryMenu: View {
    let providerID: String
    let installedModels: [String]
    @Binding var selectedModel: String

    private var models: [LocalTextModelCatalog.Model] {
        ModelRepository.shared.localTextModels.models(for: self.providerID)
    }

    var body: some View {
        Menu("Local model library") {
            ForEach(self.models) { model in
                Menu(model.title) {
                    if let installedID = model.installedID(in: self.installedModels) {
                        Button(PichiLocalization.format("Select installed model: %@", installedID)) {
                            self.selectedModel = installedID
                        }
                    } else {
                        Text("Not listed by this server")
                    }
                    Text("Summary and text cleanup candidate")
                    Text("Installation does not confirm output quality")
                    Divider()
                    Link("Publisher and installation instructions", destination: model.sourceURL)
                }
            }
            Divider()
            Text("Install models separately, then refresh the model list.")
        }
        .fluidDropdownStyle()
        .disabled(self.models.isEmpty)
        .accessibilityLabel("Local model library")
    }
}
