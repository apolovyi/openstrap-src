import Foundation
import XCTest

final class AccessorySetupTests: XCTestCase {
  func testPresentationDoesNotFinishPairing() throws {
    let picker = AccessoryPickerLifecycle()
    var responses: [Result<String, AccessoryPickerError>] = []
    let token = try XCTUnwrap(picker.begin(known: []) { responses.append($0) })
    picker.presentationCompleted(token: token, error: nil)
    XCTAssertTrue(responses.isEmpty)
    XCTAssertTrue(picker.isPicking)
    picker.presented()
    XCTAssertTrue(responses.isEmpty)
    picker.accessoryChanged(id: "selected", authorized: true)
    XCTAssertTrue(responses.isEmpty)
    picker.dismissed(authorizedIds: ["selected"])
    XCTAssertEqual(try responses.first?.get(), "selected")
    XCTAssertEqual(responses.count, 1)
    XCTAssertFalse(picker.isPicking)
  }

  func testSelectionNeverFallsBackToAnOldAccessory() throws {
    let picker = AccessoryPickerLifecycle()
    var responses: [Result<String, AccessoryPickerError>] = []
    _ = picker.begin(known: ["old"]) { responses.append($0) }
    picker.presented()
    picker.accessoryChanged(id: "old", authorized: true)
    picker.dismissed(authorizedIds: ["old"])
    XCTAssertEqual(responses, [.failure(AccessoryPickerError(message: "Pairing cancelled."))])
    _ = picker.begin(known: ["old"]) { responses.append($0) }
    picker.presented()
    picker.accessoryChanged(id: "selected", authorized: true)
    picker.dismissed(authorizedIds: ["old", "selected"])
    XCTAssertEqual(try responses.last?.get(), "selected")
  }

  func testDismissalReconcilesAnAccessoryWhoseEventIsStillQueued() throws {
    let picker = AccessoryPickerLifecycle()
    var responses: [Result<String, AccessoryPickerError>] = []
    _ = picker.begin(known: ["old"]) { responses.append($0) }
    picker.presented()
    picker.dismissed(authorizedIds: ["old", "selected"])
    picker.accessoryChanged(id: "selected", authorized: true)
    XCTAssertEqual(responses, [.success("selected")])
  }

  func testAmbiguousOrIncompleteAuthorizationDoesNotChooseADevice() {
    for candidates in [Set(["old"]), Set(["old", "a", "b"])] {
      let picker = AccessoryPickerLifecycle()
      var responses: [Result<String, AccessoryPickerError>] = []
      _ = picker.begin(known: ["old"]) { responses.append($0) }
      picker.presented()
      if candidates.count == 1 { picker.accessoryChanged(id: "selected", authorized: false) }
      picker.dismissed(authorizedIds: candidates)
      XCTAssertEqual(responses, [.failure(AccessoryPickerError(message: "Accessory authorization did not complete."))])
    }
  }

  func testDuplicateEventsAndStaleCompletionCannotResolveANewAttempt() throws {
    let picker = AccessoryPickerLifecycle()
    var first: [Result<String, AccessoryPickerError>] = []
    var second: [Result<String, AccessoryPickerError>] = []
    let oldToken = try XCTUnwrap(picker.begin(known: []) { first.append($0) })
    picker.presented()
    picker.dismissed(authorizedIds: [])
    _ = picker.begin(known: []) { second.append($0) }
    picker.dismissed(authorizedIds: [])
    picker.presentationCompleted(token: oldToken, error: AccessoryPickerError(message: "late error"))
    XCTAssertTrue(second.isEmpty)
    picker.presented()
    picker.accessoryChanged(id: "selected", authorized: true)
    picker.dismissed(authorizedIds: ["selected"])
    picker.dismissed(authorizedIds: ["selected"])
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(second, [.success("selected")])
  }

  func testConcurrentAttemptDoesNotReplaceTheFirst() {
    let picker = AccessoryPickerLifecycle()
    var first: [Result<String, AccessoryPickerError>] = []
    var second: [Result<String, AccessoryPickerError>] = []
    _ = picker.begin(known: []) { first.append($0) }
    XCTAssertNil(picker.begin(known: []) { second.append($0) })
    XCTAssertTrue(first.isEmpty)
    XCTAssertEqual(second, [.failure(AccessoryPickerError(message: "An accessory picker is already open."))])
    picker.presented()
    picker.dismissed(authorizedIds: [])
    XCTAssertEqual(first.count, 1)
  }

  func testSetupFailureWaitsForDismissalAndCanRecoverInTheSamePicker() {
    let error = AccessoryPickerError(message: "Authorization refused")
    for recovers in [false, true] {
      let picker = AccessoryPickerLifecycle()
      var responses: [Result<String, AccessoryPickerError>] = []
      _ = picker.begin(known: []) { responses.append($0) }
      picker.presented()
      picker.setupFailed(error)
      XCTAssertTrue(responses.isEmpty)
      if recovers { picker.accessoryChanged(id: "selected", authorized: true) }
      picker.dismissed(authorizedIds: recovers ? ["selected"] : [])
      XCTAssertEqual(responses, recovers ? [.success("selected")] : [.failure(error)])
    }
  }

  func testPresentationFailureAndInvalidationReleaseTheRequest() throws {
    let picker = AccessoryPickerLifecycle()
    let error = AccessoryPickerError(message: "Unavailable")
    var responses: [Result<String, AccessoryPickerError>] = []
    let token = try XCTUnwrap(picker.begin(known: []) { responses.append($0) })
    picker.presentationCompleted(token: token, error: error)
    picker.invalidate(error)
    XCTAssertEqual(responses, [.failure(error)])
    XCTAssertNotNil(picker.begin(known: []) { responses.append($0) })
    picker.invalidate(error)
    XCTAssertEqual(responses.count, 2)
    XCTAssertFalse(picker.isPicking)
  }

  func testActivationWaitsForTheEventAndSharesOneSession() throws {
    let activation = AccessorySetupActivation()
    var completions = 0
    let token = try XCTUnwrap(activation.begin { response in
      XCTAssertEqual(response.map { true }, .success(true))
      completions += 1
    })
    XCTAssertNil(activation.begin { _ in completions += 1 })
    XCTAssertEqual(completions, 0)
    XCTAssertFalse(activation.isActive)
    activation.activated(token: token)
    activation.activated(token: token)
    XCTAssertEqual(completions, 2)
    XCTAssertTrue(activation.isActive)
    XCTAssertNil(activation.begin { _ in completions += 1 })
    XCTAssertEqual(completions, 3)
  }

  func testFailedActivationReleasesWaitersAndIgnoresOldSessionEvents() throws {
    let activation = AccessorySetupActivation()
    let error = AccessoryPickerError(message: "Activation timed out")
    var failures = 0
    let oldToken = try XCTUnwrap(activation.begin { response in
      if case .failure(let received) = response {
        XCTAssertEqual(received, error)
        failures += 1
      }
    })
    activation.invalidate(error)
    XCTAssertEqual(failures, 1)
    var successes = 0
    let token = try XCTUnwrap(activation.begin { response in
      XCTAssertEqual(response.map { true }, .success(true))
      successes += 1
    })
    activation.activated(token: oldToken)
    XCTAssertFalse(activation.isActive)
    XCTAssertEqual(successes, 0)
    activation.activated(token: token)
    XCTAssertEqual(successes, 1)
  }
}

@main
struct AccessorySetupTestRunner {
  static func main() {
    let suite = XCTestSuite(forTestCaseClass: AccessorySetupTests.self)
    suite.run()
    guard let run = suite.testRun, run.executionCount > 0,
          run.executionCount == suite.testCaseCount, run.hasSucceeded else { exit(1) }
    print("Accessory setup: \(run.executionCount) tests passed")
  }
}
