import Foundation
@testable import ServiceContracts
import SparrowDomain
import Testing

@Suite("Localized errors")
struct LocalizationTests {
    /// Every case a person can be shown, so a new one cannot be added without
    /// appearing here.
    static let allCases: [ServiceError] = [
        .noteNotFound(NoteID()),
        .notebookNotFound(NotebookID()),
        .tagNotFound(TagID(normalizing: "tag")!),
        .emptyNote,
        .emptyNotebookName,
        .emptyTagLabel,
        .notebookNotEmpty(NotebookID()),
        .storageUnavailable,
    ]

    @Test("Every case has a description and a recovery suggestion",
          arguments: allCases)
    func everyCaseIsPresentable(error: ServiceError) throws {
        let description = try #require(error.errorDescription)
        let recovery = try #require(error.recoverySuggestion)

        #expect(!description.isEmpty)
        #expect(!recovery.isEmpty)
    }

    /// ⚠️ **The check that a missing catalog would otherwise pass.**
    ///
    /// The keys *are* the English text, so a lookup that failed entirely would
    /// still read perfectly in English. Asserting the strings differ from the
    /// key proves the bundle was found — and there is nothing to assert in
    /// English, so this has to look at the other language.
    @Test("Every string resolves in French, and differs from the English",
          arguments: allCases)
    func frenchResolves(error: ServiceError) throws {
        let french = try #require(Self.bundle(for: "fr"))

        let englishDescription = try #require(error.errorDescription)
        let frenchDescription = french.localizedString(
            forKey: englishDescription, value: nil, table: "Localizable"
        )
        #expect(frenchDescription != englishDescription,
                "no French for: \(englishDescription)")

        let englishRecovery = try #require(error.recoverySuggestion)
        let frenchRecovery = french.localizedString(
            forKey: englishRecovery, value: nil, table: "Localizable"
        )
        #expect(frenchRecovery != englishRecovery,
                "no French for: \(englishRecovery)")
    }

    @Test("The package carries both locales")
    func bothLocalesArePresent() throws {
        let localizations = Set(Bundle.module.localizations)
        #expect(localizations.contains("en"))
        #expect(localizations.contains("fr"))
    }

    /// The `.lproj` the catalog compiles into, for the language asked for.
    private static func bundle(for language: String) -> Bundle? {
        Bundle.module.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:))
    }
}
