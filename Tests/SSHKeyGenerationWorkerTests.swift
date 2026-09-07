import XCTest
#if SWIFT_PACKAGE
@testable import KeyHarness
#endif

final class SSHKeyGenerationWorkerTests: XCTestCase {
    func testCanceledRequestDoesNotGenerateAKey() async {
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SSHKeyGenerationWorker.shared.generate(name: "Canceled request")
        }
        do {
            _ = try await request.value
            XCTFail("A canceled request must not generate a key")
        } catch is CancellationError {
            // Cancellation must be checked before entering native generation.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }
}
