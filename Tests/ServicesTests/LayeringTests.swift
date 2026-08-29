import Foundation
import ServiceContracts
import SparrowDomain
import StorageContracts
import Testing
@testable import Services

@Suite("Layering")
struct LayeringTests {
    /// A `ServiceError` must be all the layers above ever see. If a
    /// `StorageError` escapes, an intent has to know storage vocabulary to
    /// describe what went wrong.
    @Test("Storage errors never escape as themselves")
    func storageErrorsAreTranslated() async throws {
        let (service, _) = try makeService()

        do {
            try await service.delete(NoteID())
            Issue.record("expected a failure")
        } catch is StorageError {
            Issue.record("a StorageError escaped the service layer")
        } catch let error as ServiceError {
            #expect(error == .noteNotFound(error.missingID ?? NoteID()))
        }
    }

    @Test("Every ServiceError carries something a person can read")
    func everyErrorIsPresentable() {
        let errors: [ServiceError] = [
            .noteNotFound(NoteID()),
            .emptyNote,
            .storageUnavailable,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }
}

private extension ServiceError {
    var missingID: NoteID? {
        if case .noteNotFound(let id) = self { id } else { nil }
    }
}
