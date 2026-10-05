// Shared source. Run `dart run tool/sync_apple.dart` after editing.
import Foundation
import ImageCaptureCore
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

final class FujiUsb: NSObject, ICDeviceBrowserDelegate, ICDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    private var selected: ICCameraDevice?
    private var opening: FlutterResult?
    private var openingID = UUID()
    private var pending: FlutterResult?
    private var requestID = UUID()
    private var channel: FlutterMethodChannel?

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        let channel = FlutterMethodChannel(name: "dev.reikop.fuji_san/usb", binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    }
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "discover":
            #if os(iOS)
            browser.requestControlAuthorization { status in
                DispatchQueue.main.async {
                    guard status == .authorized else {
                        result(FlutterError(code: "permission", message: "Allow camera control access in Settings.", details: nil)); return
                    }
                    self.discover(result)
                }
            }
            #else
            discover(result)
            #endif
        case "connect":
            guard opening == nil, selected == nil,
                  let args = call.arguments as? [String: Any], let id = args["id"] as? String,
                  let camera = cameras[id] else {
                result(FlutterError(code: "device", message: "Camera missing or session already open.", details: nil)); return
            }
            selected = camera; opening = result; camera.delegate = self
            let openID = UUID(); openingID = openID
            camera.requestOpenSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self = self, self.openingID == openID, let finish = self.opening else { return }
                self.opening = nil; self.selected?.requestCloseSession(); self.selected = nil
                finish(FlutterError(code: "timeout", message: "Camera session timed out. Reconnect USB.", details: nil))
            }
        case "disconnect":
            requestID = UUID()
            pending?(FlutterError(code: "disconnected", message: "Camera disconnected", details: nil)); pending = nil
            selected?.requestCloseSession(); selected = nil
            result(nil)
        case "transaction":
            guard pending == nil, let camera = selected, camera.hasOpenSession,
                  let args = call.arguments as? [String: Any], let command = args["command"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "session", message: "Camera is disconnected or busy", details: nil)); return
            }
            let id = UUID(); requestID = id; pending = result
            let outgoing = (args["outgoing"] as? FlutterStandardTypedData)?.data
            camera.requestSendPTPCommand(command.data, outData: outgoing) { data, response, error in
                DispatchQueue.main.async {
                    guard self.requestID == id, let finish = self.pending else { return }
                    self.pending = nil
                    if let error = error { finish(FlutterError(code: "ptp", message: error.localizedDescription, details: nil)) }
                    else { finish(["data": FlutterStandardTypedData(bytes: data), "response": FlutterStandardTypedData(bytes: response)]) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self, self.requestID == id, let finish = self.pending else { return }
                self.pending = nil; self.requestID = UUID(); self.selected?.requestCloseSession(); self.selected = nil
                finish(FlutterError(code: "timeout", message: "PTP command timed out. Reconnect the camera before retrying.", details: nil))
            }
        default: result(FlutterMethodNotImplemented)
        }
    }
    private func discover(_ result: @escaping FlutterResult) {
        if !browser.isBrowsing { browser.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            result(self.cameras.map { ["id": $0.key, "name": $0.value.name ?? "FUJIFILM USB"] })
        }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice, device.usbVendorID == 0x04cb else { return }
        cameras[device.uuidString ?? "usb-\(device.usbLocationID)"] = camera
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        cameras = cameras.filter { $0.value !== device }
        if selected === device { didRemove(device) }
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard selected === device, let finish = opening else { return }
        opening = nil
        if let error = error { selected = nil; finish(FlutterError(code: "session", message: error.localizedDescription, details: nil)) }
        else { finish(["managedSession": true]) }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if selected === device { selected = nil }
    }
    func didRemove(_ device: ICDevice) {
        selected = nil; requestID = UUID()
        let error = FlutterError(code: "disconnected", message: "USB camera removed", details: nil)
        opening?(error); opening = nil; pending?(error); pending = nil
    }
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        guard let error = error else { return }
        pending?(FlutterError(code: "camera", message: error.localizedDescription, details: nil)); pending = nil
    }
}
