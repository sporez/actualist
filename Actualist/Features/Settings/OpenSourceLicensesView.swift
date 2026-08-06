import SwiftUI

struct OpenSourceLicensesView: View {
    private let actualistLicense = BundledLicenseDocument.load(
        name: "LICENSE",
        fileExtension: nil
    )
    private let thirdPartyNotices = BundledLicenseDocument.load(
        name: "THIRD_PARTY_NOTICES",
        fileExtension: "md"
    )
    private let appStoreException = BundledLicenseDocument.load(
        name: "APP_STORE_EXCEPTION",
        fileExtension: "md"
    )

    var body: some View {
        List {
            Section("Actualist") {
                Text("Copyright © 2026 Neil DeLillo")
                Text("Actualist source code is licensed under GNU GPL version 3, with an App Store and TestFlight exception.")
                    .foregroundStyle(ActualistTheme.secondaryText)

                Link("View Source Code", destination: URL(string: "https://github.com/sporez/actualist")!)

                DisclosureGroup("GNU GPLv3 License") {
                    licenseText(actualistLicense)
                }

                DisclosureGroup("App Store and TestFlight Exception") {
                    licenseText(appStoreException)
                }
            }
            .settingsSectionChrome()

            Section("Third-Party Software") {
                Text("Actualist includes software distributed under compatible open-source licenses.")
                    .foregroundStyle(ActualistTheme.secondaryText)

                DisclosureGroup("Notices and Licenses") {
                    licenseText(thirdPartyNotices)
                }
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Open Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseText(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(.vertical, 8)
    }
}

private enum BundledLicenseDocument {
    static func load(name: String, fileExtension: String?) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This license document could not be loaded. Visit github.com/sporez/actualist for the complete text."
        }

        return text
    }
}
