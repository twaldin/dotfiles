import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import IOBluetooth

private let schemaVersion = 1

private enum NameAuthorization: String, Encodable {
    case authorized
    case denied
    case notDetermined = "not_determined"
    case restricted
    case servicesDisabled = "services_disabled"
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

private struct WiFiNameDocument: Encodable {
    let schema = schemaVersion
    let ok = true
    let authorization: NameAuthorization
    let ssid: String?
    let phy: String?
    let channel: Int?
    let band: String?
    let channelWidth: String?
    let countryCode: String?
    private enum CodingKeys: String, CodingKey {
        case schema, ok, authorization, ssid, phy, channel, band
        case channelWidth = "channel_width"
        case countryCode = "country_code"
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(ok, forKey: .ok)
        try values.encode(authorization, forKey: .authorization)
        try values.encodeNullable(ssid, forKey: .ssid)
        try values.encodeNullable(phy, forKey: .phy)
        try values.encodeNullable(channel, forKey: .channel)
        try values.encodeNullable(band, forKey: .band)
        try values.encodeNullable(channelWidth, forKey: .channelWidth)
        try values.encodeNullable(countryCode, forKey: .countryCode)
    }
}

private struct BluetoothDeviceDocument: Encodable {
    let address: String
    let name: String
    let connected: Bool
    let paired: Bool
    let rssi: Int?
    let type: String?
    let profiles: [String]
    private enum CodingKeys: String, CodingKey { case address, name, connected, paired, rssi, type, profiles }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(address, forKey: .address)
        try values.encode(name, forKey: .name)
        try values.encode(connected, forKey: .connected)
        try values.encode(paired, forKey: .paired)
        try values.encodeNullable(rssi, forKey: .rssi)
        try values.encodeNullable(type, forKey: .type)
        try values.encode(profiles, forKey: .profiles)
    }
}

private struct BluetoothDocument: Encodable {
    let schema = schemaVersion
    let ok = true
    let devices: [BluetoothDeviceDocument]
}

private func nameAuthorization() -> NameAuthorization {
    guard CLLocationManager.locationServicesEnabled() else { return .servicesDisabled }
    switch CLLocationManager().authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: return .authorized
    case .denied: return .denied
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    @unknown default: return .restricted
    }
}

private func phyName(_ value: CWPHYMode) -> String? {
    switch value {
    case .mode11a: return "802.11a"
    case .mode11ac: return "802.11ac"
    case .mode11b: return "802.11b"
    case .mode11g: return "802.11g"
    case .mode11n: return "802.11n"
    case .mode11ax: return "802.11ax"
    case .mode11be: return "802.11be"
    case .modeNone: return nil
    @unknown default: return nil
    }
}

private func bandName(_ value: CWChannelBand) -> String? {
    switch value {
    case .band2GHz: return "2 GHz"
    case .band5GHz: return "5 GHz"
    case .band6GHz: return "6 GHz"
    case .bandUnknown: return nil
    @unknown default: return nil
    }
}

private func widthName(_ value: CWChannelWidth) -> String? {
    switch value {
    case .width20MHz: return "20 MHz"
    case .width40MHz: return "40 MHz"
    case .width80MHz: return "80 MHz"
    case .width160MHz: return "160 MHz"
    case .widthUnknown: return nil
    @unknown default: return nil
    }
}

private func wifiNameDocument() -> WiFiNameDocument {
    let authorization = nameAuthorization()
    let interface = CWWiFiClient.shared().interface()
    let channel = interface?.wlanChannel()
    let country = interface?.countryCode().flatMap { value in
        value.range(of: "^[A-Z]{2}$", options: .regularExpression) == nil ? nil : value
    }
    return WiFiNameDocument(
        authorization: authorization,
        ssid: authorization == .authorized ? interface?.ssid() : nil,
        phy: interface.flatMap { phyName($0.activePHYMode()) },
        channel: channel?.channelNumber,
        band: channel.flatMap { bandName($0.channelBand) },
        channelWidth: channel.flatMap { widthName($0.channelWidth) },
        countryCode: country
    )
}

private let profileUUIDs: [(BluetoothSDPUUID16, String)] = [
    (0x1105, "OBEX"), (0x1106, "File transfer"),
    (0x1108, "Headset"), (0x110A, "A2DP source"),
    (0x110B, "A2DP sink"), (0x110C, "AVRCP target"),
    (0x110E, "AVRCP"), (0x1112, "Headset gateway"),
    (0x1115, "PAN"), (0x1116, "Network access"),
    (0x111E, "Hands-free"), (0x111F, "Hands-free gateway"),
    (0x1124, "HID"),
]

private func deviceType(_ value: BluetoothClassOfDevice) -> String? {
    let major = Int((value & 0x00001F00) >> 8)
    let minor = Int((value & 0x000000FC) >> 2)
    switch major {
    case 1:
        switch minor {
        case 1: return "Desktop computer"
        case 2: return "Server computer"
        case 3: return "Laptop"
        case 4, 5: return "Handheld computer"
        case 6: return "Wearable computer"
        default: return "Computer"
        }
    case 2:
        return minor == 3 ? "Smartphone" : "Phone"
    case 3: return "Network access point"
    case 4:
        switch minor {
        case 1: return "Headset"
        case 2: return "Hands-free audio"
        case 4: return "Microphone"
        case 5: return "Speaker"
        case 6: return "Headphones"
        case 8: return "Car audio"
        default: return "Audio device"
        }
    case 5:
        let input = minor & 0x30
        let kind = minor & 0x0F
        if input == 0x10 { return "Keyboard" }
        if input == 0x20 { return "Pointing device" }
        if input == 0x30 { return "Keyboard and pointing device" }
        switch kind {
        case 1: return "Joystick"
        case 2: return "Gamepad"
        case 3: return "Remote control"
        case 5: return "Tablet"
        case 7: return "Digital pen"
        case 8: return "Scanner"
        default: return "Peripheral"
        }
    case 6:
        var types: [String] = []
        if minor & 0x04 != 0 { types.append("Display") }
        if minor & 0x08 != 0 { types.append("Camera") }
        if minor & 0x10 != 0 { types.append("Scanner") }
        if minor & 0x20 != 0 { types.append("Printer") }
        return types.count == 1 ? types[0] : "Imaging device"
    case 7: return minor == 1 ? "Watch" : "Wearable"
    case 8:
        switch minor {
        case 1: return "Robot"
        case 2: return "Vehicle"
        case 4: return "Controller"
        case 5: return "Game"
        default: return "Toy"
        }
    case 9:
        switch minor {
        case 1: return "Blood pressure monitor"
        case 2: return "Thermometer"
        case 3: return "Scale"
        case 4: return "Glucose meter"
        case 5: return "Pulse oximeter"
        case 6: return "Heart-rate monitor"
        default: return "Health device"
        }
    default: return nil
    }
}

private func bluetoothDocument() throws -> BluetoothDocument {
    let rawDevices = IOBluetoothDevice.pairedDevices() ?? []
    guard rawDevices.count <= 512 else { throw CocoaError(.fileReadUnknown) }
    let devices = try rawDevices.map { raw -> BluetoothDeviceDocument in
        guard let device = raw as? IOBluetoothDevice else { throw CocoaError(.fileReadCorruptFile) }
        let connected = device.isConnected()
        let rawRSSI = Int(device.rawRSSI())
        let rssi = connected && (-127 ... -1).contains(rawRSSI) ? rawRSSI : nil
        let profiles = profileUUIDs.compactMap { value, name in
            let uuid = IOBluetoothSDPUUID.uuid16(value)
            return device.getServiceRecord(for: uuid) == nil ? nil : name
        }
        return BluetoothDeviceDocument(
            address: device.addressString,
            name: device.name ?? "",
            connected: connected,
            paired: device.isPaired(),
            rssi: rssi,
            type: deviceType(device.classOfDevice),
            profiles: profiles
        )
    }
    return BluetoothDocument(devices: devices)
}

private final class AuthorizationRequest: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var requested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        manager.delegate = self
        finishOrRequest()
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { NSApp.terminate(nil) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        finishOrRequest()
    }

    private func finishOrRequest() {
        if manager.authorizationStatus == .notDetermined && !requested {
            requested = true
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus != .notDetermined {
            NSApp.terminate(nil)
        }
    }
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
private enum ConnectivityMain {
    static func main() {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "wifi": try emit(wifiNameDocument())
            case "bluetooth": try emit(bluetoothDocument())
            case "request":
                let delegate = AuthorizationRequest()
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.delegate = delegate
                NSApplication.shared.run()
                _ = delegate
            default: throw CocoaError(.fileReadInvalidFileName)
            }
        } catch {
            exit(1)
        }
    }
}
