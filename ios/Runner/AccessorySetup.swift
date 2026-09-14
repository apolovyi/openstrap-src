import Foundation

struct AccessoryPickerError: Error, Equatable {
  let message: String
}

final class AccessorySetupActivation {
  private(set) var token: UUID?
  private(set) var isActive = false
  private var waiters: [(Result<Void, AccessoryPickerError>) -> Void] = []

  func begin(_ completion: @escaping (Result<Void, AccessoryPickerError>) -> Void) -> UUID? {
    if isActive {
      completion(.success(()))
      return nil
    }
    waiters.append(completion)
    guard token == nil else { return nil }
    let next = UUID()
    token = next
    return next
  }

  func activated(token: UUID) {
    guard self.token == token, !isActive else { return }
    isActive = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter(.success(())) }
  }

  func invalidate(_ error: AccessoryPickerError) {
    token = nil
    isActive = false
    let pending = waiters
    waiters = []
    for waiter in pending { waiter(.failure(error)) }
  }
}

final class AccessoryPickerLifecycle {
  private struct Request {
    let token: UUID
    let known: Set<String>
    let completion: (Result<String, AccessoryPickerError>) -> Void
    var selectedId: String?
    var setupError: AccessoryPickerError?
    var presented = false
  }

  private var request: Request?
  var isPicking: Bool { request != nil }

  func begin(known: Set<String>,
             completion: @escaping (Result<String, AccessoryPickerError>) -> Void) -> UUID? {
    guard request == nil else {
      completion(.failure(AccessoryPickerError(message: "An accessory picker is already open.")))
      return nil
    }
    let token = UUID()
    request = Request(token: token, known: known, completion: completion)
    return token
  }

  func presented() {
    request?.presented = true
  }

  func presentationCompleted(token: UUID, error: AccessoryPickerError?) {
    guard request?.token == token, let error = error else { return }
    finish(.failure(error))
  }

  func accessoryChanged(id: String, authorized: Bool) {
    guard let active = request, !active.known.contains(id) else { return }
    request?.selectedId = id
    if authorized { request?.setupError = nil }
  }

  func setupFailed(_ error: AccessoryPickerError) {
    request?.setupError = error
  }

  func dismissed(authorizedIds: Set<String>) {
    guard let active = request, active.presented else { return }
    let added = authorizedIds.subtracting(active.known)
    if let selected = active.selectedId, added.contains(selected) {
      finish(.success(selected))
    } else if active.selectedId == nil, added.count == 1, let id = added.first {
      finish(.success(id))
    } else if let error = active.setupError {
      finish(.failure(error))
    } else if active.selectedId != nil || !added.isEmpty {
      finish(.failure(AccessoryPickerError(message: "Accessory authorization did not complete.")))
    } else {
      finish(.failure(AccessoryPickerError(message: "Pairing cancelled.")))
    }
  }

  func invalidate(_ error: AccessoryPickerError) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<String, AccessoryPickerError>) {
    let completion = request?.completion
    request = nil
    completion?(result)
  }
}

#if canImport(Flutter) && canImport(AccessorySetupKit)
import Flutter
import CoreBluetooth
import AccessorySetupKit

enum AccessorySetup {
  fileprivate static let whoopMemberUUID16 = "FD4B"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "openstrap/accessory_setup", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        if #available(iOS 18.0, *) { result(true) } else { result(false) }
      case "provisionedIds":
        if #available(iOS 18.0, *) {
          AccessorySetupController.shared.provisionedIds { response in
            switch response {
            case .success(let ids): result(ids)
            case .failure(let error):
              result(FlutterError(code: "ask_session", message: error.message, details: nil))
            }
          }
        } else {
          result([String]())
        }
      case "showPicker":
        if #available(iOS 18.0, *) {
          let arguments = call.arguments as? [String: Any] ?? [:]
          let existingId = (arguments["addAnother"] as? Bool) == true
            ? nil : arguments["existingRemoteId"] as? String
          AccessorySetupController.shared.showPicker(existingId: existingId) { response in
            switch response {
            case .success(let id):
              NSLog("[ASK] picker authorized accessory=%@", id)
              result(id)
            case .failure(let error):
              NSLog("[ASK] picker failed: %@", error.message)
              result(FlutterError(code: "ask_picker", message: error.message, details: nil))
            }
          }
        } else {
          result(FlutterError(code: "unavailable",
                              message: "AccessorySetupKit requires iOS 18", details: nil))
        }
      case "removeAll":
        if #available(iOS 18.0, *) {
          AccessorySetupController.shared.removeAll { result(nil) }
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

@available(iOS 18.0, *)
private final class AccessorySetupController {
  static let shared = AccessorySetupController()

  private var session = ASAccessorySession()
  private let activation = AccessorySetupActivation()
  private var activationTimeout: DispatchWorkItem?
  private let picker = AccessoryPickerLifecycle()
  private var pickerStarting = false

  private var authorizedIds: Set<String> {
    Set(session.accessories.compactMap { accessory in
      guard accessory.state == .authorized else { return nil }
      return accessory.bluetoothIdentifier?.uuidString.uppercased()
    })
  }

  private func whenActivated(_ completion: @escaping (Result<Void, AccessoryPickerError>) -> Void) {
    guard let token = activation.begin(completion) else { return }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.activation.token == token, !self.activation.isActive else { return }
      self.invalidate(AccessoryPickerError(message: "Accessory setup did not activate. Try again."))
    }
    activationTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    session.activate(on: .main) { [weak self] event in
      guard let self = self, self.activation.token == token else { return }
      self.onEvent(event, token: token)
    }
  }

  private func onEvent(_ event: ASAccessoryEvent, token: UUID) {
    NSLog("[ASK] event=%ld pickerPending=%d", event.eventType.rawValue, picker.isPicking ? 1 : 0)
    switch event.eventType {
    case .activated:
      activationTimeout?.cancel()
      activationTimeout = nil
      activation.activated(token: token)
    case .invalidated:
      invalidate(AccessoryPickerError(message: event.error?.localizedDescription
        ?? "Accessory setup was interrupted. Try again."))
    case .pickerDidPresent:
      picker.presented()
    case .accessoryAdded, .accessoryChanged:
      if let accessory = event.accessory, let id = accessory.bluetoothIdentifier?.uuidString {
        picker.accessoryChanged(id: id.uppercased(), authorized: accessory.state == .authorized)
      }
    case .pickerSetupFailed:
      picker.setupFailed(AccessoryPickerError(message: event.error?.localizedDescription
        ?? "The system could not authorize the accessory."))
    case .pickerDidDismiss:
      picker.dismissed(authorizedIds: authorizedIds)
    default:
      break
    }
  }

  private func invalidate(_ error: AccessoryPickerError) {
    activationTimeout?.cancel()
    activationTimeout = nil
    let previousSession = session
    session = ASAccessorySession()
    activation.invalidate(error)
    picker.invalidate(error)
    previousSession.invalidate()
  }

  func provisionedIds(_ completion: @escaping (Result<[String], AccessoryPickerError>) -> Void) {
    whenActivated { [weak self] response in
      guard let self = self else { return }
      completion(response.map { self.authorizedIds.sorted() })
    }
  }

  func showPicker(existingId: String?,
                  _ completion: @escaping (Result<String, AccessoryPickerError>) -> Void) {
    guard !pickerStarting, !picker.isPicking else {
      completion(.failure(AccessoryPickerError(message: "An accessory picker is already open.")))
      return
    }
    pickerStarting = true
    whenActivated { [weak self] response in
      guard let self = self else { return }
      self.pickerStarting = false
      if case .failure(let error) = response {
        completion(.failure(error))
        return
      }
      if let existingId = existingId?.uppercased(), self.authorizedIds.contains(existingId) {
        completion(.success(existingId))
        return
      }
      let productImage = UIImage(named: "StrapProduct")
        ?? UIImage(systemName: "sensor.tag.radiowave.forward") ?? UIImage()
      func makeItem(_ label: String,
                    _ configure: (ASDiscoveryDescriptor) -> Void) -> ASPickerDisplayItem {
        let descriptor = ASDiscoveryDescriptor()
        configure(descriptor)
        return ASPickerDisplayItem(name: label, productImage: productImage, descriptor: descriptor)
      }
      let info = Bundle.main.infoDictionary ?? [:]
      let services = info["NSAccessorySetupBluetoothServices"] as? [String] ?? []
      let labels = info["OSBandLabels"] as? [String: String] ?? [:]
      var items = services.map { service in
        makeItem(labels[service.uppercased()] ?? "Band") {
          $0.bluetoothServiceUUID = CBUUID(string: service)
        }
      }
      guard !items.isEmpty else {
        completion(.failure(AccessoryPickerError(message: "No accessory services are declared in Info.plist.")))
        return
      }
      items.append(makeItem("WHOOP 5.0 / MG") {
        $0.bluetoothServiceUUID = CBUUID(string: AccessorySetup.whoopMemberUUID16)
      })
      guard let token = self.picker.begin(known: self.authorizedIds, completion: completion) else { return }
      self.session.showPicker(for: items) { [weak self] error in
        DispatchQueue.main.async {
          guard let self = self else { return }
          let failure = error.map { error in
            AccessoryPickerError(message: (error as? ASError)?.code == .userCancelled
              ? "Pairing cancelled." : error.localizedDescription)
          }
          NSLog("[ASK] picker presentation completed error=%@", failure?.message ?? "none")
          self.picker.presentationCompleted(token: token, error: failure)
        }
      }
    }
  }

  func removeAll(_ completion: @escaping () -> Void) {
    whenActivated { [weak self] response in
      guard let self = self else { return }
      if case .failure(let error) = response {
        NSLog("[ASK] accessory removal failed: %@", error.message)
        completion()
        return
      }
      let group = DispatchGroup()
      for accessory in self.session.accessories {
        group.enter()
        self.session.removeAccessory(accessory) { error in
          if let error = error { NSLog("[ASK] accessory removal failed: %@", error.localizedDescription) }
          group.leave()
        }
      }
      group.notify(queue: .main, execute: completion)
    }
  }
}
#endif
