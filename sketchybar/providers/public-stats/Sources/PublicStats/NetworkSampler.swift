import Darwin
import Dispatch
import Foundation
import Network

struct LinkTotals: Equatable, Sendable {
    let receive: UInt64
    let transmit: UInt64
}

struct LinkCounterSample: Equatable, Sendable {
    let totals: LinkTotals
    let lanes: [LinkTotals]

    init(totals: LinkTotals, lanes: [LinkTotals]? = nil) {
        self.totals = totals
        self.lanes = lanes ?? [totals]
    }
}

func linkCounterABICompatible() -> Bool {
    let value = if_data()
    let receive: UInt32 = value.ifi_ibytes
    let transmit: UInt32 = value.ifi_obytes
    return MemoryLayout<if_data>.size == 96
        && MemoryLayout.size(ofValue: receive) == 4
        && MemoryLayout.size(ofValue: transmit) == 4
}

func readLinkCounterSample(names: Set<String>) -> LinkCounterSample? {
    guard linkCounterABICompatible(), !names.isEmpty else { return nil }
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(first) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    var values: [String: LinkTotals] = [:]
    while let pointer = cursor {
        let entry = pointer.pointee
        cursor = entry.ifa_next
        guard let rawName = entry.ifa_name else { continue }
        let name = String(cString: rawName)
        guard names.contains(name), values[name] == nil,
              let address = entry.ifa_addr,
              Int32(address.pointee.sa_family) == AF_LINK,
              let rawData = entry.ifa_data else { continue }
        let data = rawData.assumingMemoryBound(to: if_data.self).pointee
        values[name] = LinkTotals(receive: UInt64(data.ifi_ibytes),
                                  transmit: UInt64(data.ifi_obytes))
    }
    guard Set(values.keys) == names else { return nil }
    let lanes = names.sorted().compactMap { values[$0] }
    var receive: UInt64 = 0
    var transmit: UInt64 = 0
    for lane in lanes {
        let (nextReceive, receiveOverflow) = receive.addingReportingOverflow(lane.receive)
        let (nextTransmit, transmitOverflow) = transmit.addingReportingOverflow(lane.transmit)
        guard !receiveOverflow, !transmitOverflow else { return nil }
        receive = nextReceive
        transmit = nextTransmit
    }
    return LinkCounterSample(totals: LinkTotals(receive: receive, transmit: transmit), lanes: lanes)
}

func hasReadableLinkCounter() -> Bool {
    guard linkCounterABICompatible() else { return false }
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return false }
    defer { freeifaddrs(first) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let pointer = cursor {
        let entry = pointer.pointee
        cursor = entry.ifa_next
        guard let address = entry.ifa_addr,
              Int32(address.pointee.sa_family) == AF_LINK,
              let rawData = entry.ifa_data else { continue }
        _ = rawData.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes
        return true
    }
    return false
}

struct NetworkObservation: Equatable, Sendable {
    let sampled: Bool
    let valid: Bool
    let state: PathState
    let type: PathType
    let receiveBytesPerSecond: UInt64
    let transmitBytesPerSecond: UInt64
    let expensive: Bool
    let constrained: Bool
}

struct LinkRateBaseline: Equatable, Sendable {
    let sample: LinkCounterSample
    let timeNanoseconds: UInt64
    let selection: Set<String>
}

func calculateLinkRate(previous: LinkRateBaseline,
                       current: LinkCounterSample,
                       selection: Set<String>,
                       timeNanoseconds: UInt64) -> (UInt64, UInt64)? {
    guard previous.selection == selection,
          timeNanoseconds > previous.timeNanoseconds,
          current.lanes.count == previous.sample.lanes.count else { return nil }
    let elapsed = timeNanoseconds - previous.timeNanoseconds
    guard elapsed <= 12_000_000_000 else { return nil }
    var receiveDelta: UInt64 = 0
    var transmitDelta: UInt64 = 0
    for (old, new) in zip(previous.sample.lanes, current.lanes) {
        guard new.receive >= old.receive, new.transmit >= old.transmit else { return nil }
        let (nextReceive, receiveOverflow) = receiveDelta.addingReportingOverflow(new.receive - old.receive)
        let (nextTransmit, transmitOverflow) = transmitDelta.addingReportingOverflow(new.transmit - old.transmit)
        guard !receiveOverflow, !transmitOverflow else { return nil }
        receiveDelta = nextReceive
        transmitDelta = nextTransmit
    }
    let receiveRate = Double(receiveDelta) * 1_000_000_000 / Double(elapsed)
    let transmitRate = Double(transmitDelta) * 1_000_000_000 / Double(elapsed)
    guard receiveRate.isFinite, transmitRate.isFinite,
          receiveRate >= 0, transmitRate >= 0,
          receiveRate < Double(UInt64.max), transmitRate < Double(UInt64.max) else { return nil }
    return (UInt64(receiveRate.rounded()), UInt64(transmitRate.rounded()))
}

struct PathSelection: Equatable, Sendable {
    let state: PathState
    let type: PathType
    let names: Set<String>
    let expensive: Bool
    let constrained: Bool

    var throughputEligible: Bool {
        state == .satisfied && [.wifi, .wired, .cellular, .multiple].contains(type) && !names.isEmpty
    }
}


func classifyPathType(state: PathState, wifi: Bool, wired: Bool, cellular: Bool,
                      other: Bool, loopback: Bool) -> PathType {
    let physicalCount = [wifi, wired, cellular].filter { $0 }.count
    if physicalCount > 1 { return .multiple }
    if wifi { return .wifi }
    if wired { return .wired }
    if cellular { return .cellular }
    if other || loopback { return .other }
    if state == .unsatisfied { return .none }
    return .unknown
}

func mapPath(_ path: NWPath) -> PathSelection {
    let state: PathState
    switch path.status {
    case .satisfied: state = .satisfied
    case .unsatisfied: state = .unsatisfied
    case .requiresConnection: state = .requires_connection
    @unknown default: state = .unknown
    }

    let wifi = path.usesInterfaceType(.wifi)
    let wired = path.usesInterfaceType(.wiredEthernet)
    let cellular = path.usesInterfaceType(.cellular)
    let physicalCount = [wifi, wired, cellular].filter { $0 }.count
    let type = classifyPathType(state: state, wifi: wifi, wired: wired,
                                cellular: cellular,
                                other: path.usesInterfaceType(.other),
                                loopback: path.usesInterfaceType(.loopback))

    let names: Set<String>
    if state == .satisfied && physicalCount > 0 {
        names = Set(path.availableInterfaces.compactMap { interface in
            switch interface.type {
            case .wifi where wifi: return interface.name
            case .wiredEthernet where wired: return interface.name
            case .cellular where cellular: return interface.name
            default: return nil
            }
        })
    } else {
        names = []
    }
    return PathSelection(state: state, type: type, names: names,
                         expensive: path.isExpensive, constrained: path.isConstrained)
}

struct NetworkSampler: Sendable {
    private(set) var selection: PathSelection?
    private(set) var baseline: LinkRateBaseline?

    mutating func clear() { baseline = nil; selection = nil }

    mutating func replacePathAfterReset(_ path: NWPath) -> NetworkObservation {
        clear()
        let next = mapPath(path)
        selection = next
        return NetworkObservation(sampled: false, valid: false, state: next.state, type: next.type,
                                  receiveBytesPerSecond: 0, transmitBytesPerSecond: 0,
                                  expensive: next.expensive, constrained: next.constrained)
    }

    mutating func consume(path: NWPath, timeNanoseconds: UInt64) -> NetworkObservation {
        let next = mapPath(path)
        if selection?.state != next.state || selection?.type != next.type || selection?.names != next.names {
            baseline = nil
        }
        selection = next
        return sample(timeNanoseconds: timeNanoseconds)
    }

    mutating func sample(timeNanoseconds: UInt64,
                         reader: (Set<String>) -> LinkCounterSample? = readLinkCounterSample) -> NetworkObservation {
        guard let selection else {
            return NetworkObservation(sampled: false, valid: false, state: .unknown, type: .unknown,
                                      receiveBytesPerSecond: 0, transmitBytesPerSecond: 0,
                                      expensive: false, constrained: false)
        }
        guard selection.throughputEligible,
              let counterSample = reader(selection.names) else {
            baseline = nil
            return observation(selection, valid: false, receive: 0, transmit: 0)
        }
        let newBaseline = LinkRateBaseline(sample: counterSample, timeNanoseconds: timeNanoseconds,
                                           selection: selection.names)
        defer { baseline = newBaseline }
        guard let baseline,
              let rates = calculateLinkRate(previous: baseline, current: counterSample,
                                            selection: selection.names,
                                            timeNanoseconds: timeNanoseconds) else {
            return observation(selection, valid: false, receive: 0, transmit: 0)
        }
        return observation(selection, valid: true, receive: rates.0, transmit: rates.1)
    }

    private func observation(_ selection: PathSelection, valid: Bool,
                             receive: UInt64, transmit: UInt64) -> NetworkObservation {
        NetworkObservation(sampled: true, valid: valid, state: selection.state, type: selection.type,
                           receiveBytesPerSecond: receive, transmitBytesPerSecond: transmit,
                           expensive: selection.expensive, constrained: selection.constrained)
    }
}
