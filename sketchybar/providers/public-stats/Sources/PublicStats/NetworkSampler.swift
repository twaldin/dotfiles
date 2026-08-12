import Darwin
import Dispatch
import Foundation
import Network
import SystemConfiguration

struct LinkTotals: Equatable, Sendable {
    let receive: UInt64
    let transmit: UInt64
}

struct LinkCounterSample: Equatable, Sendable {
    let index: UInt32
    let totals: LinkTotals
}

func roundedBytesPerSecond(delta: UInt64, elapsedNanoseconds: UInt64) -> UInt64? {
    guard elapsedNanoseconds > 0 else { return nil }
    let product = delta.multipliedFullWidth(by: 1_000_000_000)
    guard product.high < elapsedNanoseconds else { return nil }
    let division = elapsedNanoseconds.dividingFullWidth(product)
    let threshold = elapsedNanoseconds / 2 + elapsedNanoseconds % 2
    if division.remainder >= threshold {
        let (rounded, overflow) = division.quotient.addingReportingOverflow(1)
        return overflow ? nil : rounded
    }
    return division.quotient
}

func primaryIPv4Interface(from value: Any?) -> String? {
    guard let dictionary = value as? [String: Any],
          let name = dictionary["PrimaryInterface"] as? String,
          !name.isEmpty, !name.utf8.contains(0) else { return nil }
    return name
}

func readPrimaryIPv4Interface(
    reader: (CFString) -> CFPropertyList? = { key in
        SCDynamicStoreCopyValue(nil, key)
    }
) -> String? {
    primaryIPv4Interface(from: reader("State:/Network/Global/IPv4" as CFString))
}

func parseInterfaceCounters(_ data: Data, requestedIndex: UInt32) -> LinkTotals? {
    guard requestedIndex <= UInt32(UInt16.max) else { return nil }
    var offset = 0
    var found: LinkTotals?
    while offset < data.count {
        guard data.count - offset >= 4 else { return nil }
        let messageLength = data.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
        guard messageLength >= 4, messageLength <= data.count - offset else { return nil }
        let messageType = data[offset + 3]
        if messageType == UInt8(RTM_IFINFO2) {
            guard messageLength >= MemoryLayout<if_msghdr2>.size else { return nil }
            let header = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            }
            guard Int(header.ifm_msglen) == messageLength,
                  Int32(header.ifm_version) == RTM_VERSION else { return nil }
            if UInt32(header.ifm_index) == requestedIndex {
                guard found == nil else { return nil }
                found = LinkTotals(receive: header.ifm_data.ifi_ibytes,
                                   transmit: header.ifm_data.ifi_obytes)
            }
        }
        offset += messageLength
    }
    return found
}

private func readRouteInterfaceBuffer(index: UInt32) -> Data? {
    guard index > 0, index <= UInt32(UInt16.max) else { return nil }
    var mib = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
    var required = 0
    guard sysctl(&mib, u_int(mib.count), nil, &required, nil, 0) == 0,
          required >= 4, required <= 1_048_576 else { return nil }
    let capacity = required
    var data = Data(count: capacity)
    let status = data.withUnsafeMutableBytes { bytes in
        sysctl(&mib, u_int(mib.count), bytes.baseAddress, &required, nil, 0)
    }
    guard status == 0, required >= 4, required <= capacity else { return nil }
    if required < capacity { data.removeSubrange(required..<capacity) }
    return data
}

func readPrimaryLinkCounter(
    interfaceReader: () -> String? = { readPrimaryIPv4Interface() },
    indexReader: (UnsafePointer<CChar>) -> UInt32 = if_nametoindex,
    bufferReader: (UInt32) -> Data? = readRouteInterfaceBuffer
) -> LinkCounterSample? {
    guard let name = interfaceReader() else { return nil }
    let index = name.withCString(indexReader)
    guard index > 0, let data = bufferReader(index),
          let totals = parseInterfaceCounters(data, requestedIndex: index) else { return nil }
    return LinkCounterSample(index: index, totals: totals)
}

func hasReadablePrimaryLinkCounter() -> Bool {
    readPrimaryLinkCounter() != nil
}

struct NetworkObservation: Equatable, Sendable {
    let sampled: Bool
    let valid: Bool
    let state: PathState
    let type: PathType
    let receiveBytesPerSecond: UInt64
    let transmitBytesPerSecond: UInt64
    let sessionValid: Bool
    let sessionReceiveBytes: UInt64
    let sessionTransmitBytes: UInt64
    let expensive: Bool
    let constrained: Bool
}

struct LinkRateBaseline: Equatable, Sendable {
    let sample: LinkCounterSample
    let timeNanoseconds: UInt64
}

struct LinkDelta: Equatable, Sendable {
    let receive: UInt64
    let transmit: UInt64
    let elapsedNanoseconds: UInt64
}

func calculateLinkDelta(previous: LinkRateBaseline,
                        current: LinkCounterSample,
                        timeNanoseconds: UInt64) -> LinkDelta? {
    guard previous.sample.index == current.index,
          timeNanoseconds > previous.timeNanoseconds,
          current.totals.receive >= previous.sample.totals.receive,
          current.totals.transmit >= previous.sample.totals.transmit else { return nil }
    let elapsed = timeNanoseconds - previous.timeNanoseconds
    guard elapsed <= 12_000_000_000 else { return nil }
    return LinkDelta(receive: current.totals.receive - previous.sample.totals.receive,
                     transmit: current.totals.transmit - previous.sample.totals.transmit,
                     elapsedNanoseconds: elapsed)
}

func linkRates(_ delta: LinkDelta) -> (UInt64, UInt64)? {
    guard let receive = roundedBytesPerSecond(delta: delta.receive,
                                              elapsedNanoseconds: delta.elapsedNanoseconds),
          let transmit = roundedBytesPerSecond(delta: delta.transmit,
                                               elapsedNanoseconds: delta.elapsedNanoseconds),
          receive <= maximumLuaExactInteger, transmit <= maximumLuaExactInteger else { return nil }
    return (receive, transmit)
}

func addingSessionTotals(_ current: LinkTotals, delta: LinkDelta) -> LinkTotals? {
    let (receive, receiveOverflow) = current.receive.addingReportingOverflow(delta.receive)
    let (transmit, transmitOverflow) = current.transmit.addingReportingOverflow(delta.transmit)
    guard !receiveOverflow, !transmitOverflow,
          receive <= maximumLuaExactInteger, transmit <= maximumLuaExactInteger else { return nil }
    return LinkTotals(receive: receive, transmit: transmit)
}

struct PathSelection: Equatable, Sendable {
    let state: PathState
    let type: PathType
    let expensive: Bool
    let constrained: Bool

    var throughputEligible: Bool { state == .satisfied }
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
    return PathSelection(
        state: state,
        type: classifyPathType(
            state: state,
            wifi: path.usesInterfaceType(.wifi),
            wired: path.usesInterfaceType(.wiredEthernet),
            cellular: path.usesInterfaceType(.cellular),
            other: path.usesInterfaceType(.other),
            loopback: path.usesInterfaceType(.loopback)
        ),
        expensive: path.isExpensive,
        constrained: path.isConstrained
    )
}

struct NetworkSampler: Sendable {
    private(set) var selection: PathSelection?
    private(set) var baseline: LinkRateBaseline?
    private(set) var sessionReceiveBytes: UInt64 = 0
    private(set) var sessionTransmitBytes: UInt64 = 0
    private(set) var sessionEstablished = false
    private(set) var sessionTotalsInvalid = false

    mutating func resetBaseline() {
        baseline = nil
        selection = nil
        invalidateSession()
    }

    mutating func replacePathAfterReset(
        _ path: NWPath,
        timeNanoseconds: UInt64,
        reader: () -> LinkCounterSample? = { readPrimaryLinkCounter() }
    ) -> NetworkObservation {
        resetBaseline()
        return consume(path: path, timeNanoseconds: timeNanoseconds, reader: reader)
    }

    mutating func consume(
        path: NWPath,
        timeNanoseconds: UInt64,
        reader: () -> LinkCounterSample? = { readPrimaryLinkCounter() }
    ) -> NetworkObservation {
        consume(selection: mapPath(path), timeNanoseconds: timeNanoseconds, reader: reader)
    }

    mutating func consume(
        selection next: PathSelection,
        timeNanoseconds: UInt64,
        reader: () -> LinkCounterSample?
    ) -> NetworkObservation {
        if selection?.state != next.state || selection?.type != next.type {
            baseline = nil
            invalidateSession()
        }
        selection = next
        return sample(timeNanoseconds: timeNanoseconds, reader: reader)
    }

    private mutating func invalidateSession() {
        sessionEstablished = false
        sessionTotalsInvalid = false
        sessionReceiveBytes = 0
        sessionTransmitBytes = 0
    }

    mutating func sample(
        timeNanoseconds: UInt64,
        reader: () -> LinkCounterSample? = { readPrimaryLinkCounter() }
    ) -> NetworkObservation {
        guard let selection else { return unsampledObservation() }
        guard selection.throughputEligible, let counterSample = reader() else {
            baseline = nil
            invalidateSession()
            return observation(selection, valid: false, receive: 0, transmit: 0)
        }
        let newBaseline = LinkRateBaseline(sample: counterSample, timeNanoseconds: timeNanoseconds)
        guard let baseline else {
            self.baseline = newBaseline
            sessionEstablished = true
            return observation(selection, valid: false, receive: 0, transmit: 0)
        }
        guard let delta = calculateLinkDelta(previous: baseline, current: counterSample,
                                             timeNanoseconds: timeNanoseconds) else {
            self.baseline = nil
            invalidateSession()
            return observation(selection, valid: false, receive: 0, transmit: 0)
        }
        self.baseline = newBaseline
        addToSession(delta)
        guard let rates = linkRates(delta) else {
            return observation(selection, valid: false, receive: 0, transmit: 0)
        }
        return observation(selection, valid: true, receive: rates.0, transmit: rates.1)
    }

    private mutating func addToSession(_ delta: LinkDelta) {
        guard !sessionTotalsInvalid,
              let totals = addingSessionTotals(
                  LinkTotals(receive: sessionReceiveBytes, transmit: sessionTransmitBytes),
                  delta: delta
              ) else {
            sessionTotalsInvalid = true
            sessionReceiveBytes = 0
            sessionTransmitBytes = 0
            return
        }
        sessionEstablished = true
        sessionReceiveBytes = totals.receive
        sessionTransmitBytes = totals.transmit
    }

    private func unsampledObservation() -> NetworkObservation {
        NetworkObservation(sampled: false, valid: false, state: .unknown, type: .unknown,
                           receiveBytesPerSecond: 0, transmitBytesPerSecond: 0,
                           sessionValid: false, sessionReceiveBytes: 0, sessionTransmitBytes: 0,
                           expensive: false, constrained: false)
    }

    private func observation(_ selection: PathSelection, valid: Bool,
                             receive: UInt64, transmit: UInt64) -> NetworkObservation {
        let totalsValid = sessionEstablished && !sessionTotalsInvalid
        return NetworkObservation(
            sampled: true, valid: valid, state: selection.state, type: selection.type,
            receiveBytesPerSecond: receive, transmitBytesPerSecond: transmit,
            sessionValid: totalsValid,
            sessionReceiveBytes: totalsValid ? sessionReceiveBytes : 0,
            sessionTransmitBytes: totalsValid ? sessionTransmitBytes : 0,
            expensive: selection.expensive, constrained: selection.constrained
        )
    }
}
