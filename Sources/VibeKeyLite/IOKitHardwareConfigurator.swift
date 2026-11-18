import Foundation
import IOKit.hid
import VibeKeyLiteCore

enum IOKitHardwareConfiguratorError: LocalizedError {
    case managerOpenFailed(code: IOReturn)
    case deviceNotFound
    case deviceOpenFailed(code: IOReturn)
    case offlineWriteFailed(code: IOReturn)
    case reportWriteFailed(index: UInt8, code: IOReturn)
    case unsupportedAction(control: InputControl, actionName: String)

    var errorDescription: String? {
        switch self {
        case let .managerOpenFailed(code):
            "无法开启 HID 管理器（\(Self.hex(code))）。"
        case .deviceNotFound:
            "找不到 VibeKey（VID 0xFFF1、PID 0x00DD、usagePage 0xFFFC、usage 1）。"
        case let .deviceOpenFailed(code):
            "找到 VibeKey，但无法开启 custom HID 介面（\(Self.hex(code))）。"
        case let .offlineWriteFailed(code):
            "AU05 无法确認回到原生模式（\(Self.hex(code))）。"
        case let .reportWriteFailed(index, code):
            "写入硬件动作 index \(index) 失败（\(Self.hex(code))）。"
        case let .unsupportedAction(control, actionName):
            "\(control.displayName) 的「\(actionName)」无法由 AU05 离线执行。"
        }
    }

    private static func hex(_ code: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: code))
    }
}

final class IOKitHardwareConfigurator: HardwareConfigurator {
    private let descriptor: VibeKeyHIDDescriptor
    private let packetDelay: TimeInterval

    init(
        descriptor: VibeKeyHIDDescriptor = .vibeKey,
        packetDelay: TimeInterval = 0.08
    ) {
        self.descriptor = descriptor
        self.packetDelay = packetDelay
    }

    func apply(profile: ProfileConfiguration) throws {
        // Resolve every slot before opening the device. An unsupported binding must
        // never leave the AU05 with only part of a new profile written.
        let preparedReports = try profile.indexedControlBindings.map { assignment in
            (assignment, try report(for: assignment))
        }

        try IOHIDListenAccess.ensure(promptForPermission: true)

        try HIDOutputSerialQueue.queue.sync {
            try applyPreparedReports(preparedReports)
        }
    }

    private func applyPreparedReports(
        _ preparedReports: [(IndexedControlBinding, [UInt8])]
    ) throws {

        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, options)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: NSNumber(value: descriptor.vendorID),
            kIOHIDProductIDKey: NSNumber(value: descriptor.productID),
            kIOHIDPrimaryUsagePageKey: NSNumber(value: descriptor.usagePage),
            kIOHIDPrimaryUsageKey: NSNumber(value: 1)
        ]

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let managerResult = IOHIDManagerOpen(manager, options)
        guard managerResult == kIOReturnSuccess else {
            throw IOKitHardwareConfiguratorError.managerOpenFailed(code: managerResult)
        }
        defer { IOHIDManagerClose(manager, options) }

        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard let device = devices.first else {
            throw IOKitHardwareConfiguratorError.deviceNotFound
        }

        let deviceResult = IOHIDDeviceOpen(device, options)
        guard deviceResult == kIOReturnSuccess else {
            throw IOKitHardwareConfiguratorError.deviceOpenFailed(code: deviceResult)
        }
        defer { IOHIDDeviceClose(device, options) }

        let offlineReport = try VibeKeyPacketCodec.softwareOnlineReport(false)
        let offlineResult = offlineReport.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(descriptor.reportID),
                buffer.baseAddress!,
                CFIndex(buffer.count)
            )
        }
        guard offlineResult == kIOReturnSuccess else {
            throw IOKitHardwareConfiguratorError.offlineWriteFailed(code: offlineResult)
        }
        Thread.sleep(forTimeInterval: packetDelay)

        for (offset, prepared) in preparedReports.enumerated() {
            let assignment = prepared.0
            let report = prepared.1
            let writeResult = report.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(descriptor.reportID),
                    buffer.baseAddress!,
                    CFIndex(buffer.count)
                )
            }

            guard writeResult == kIOReturnSuccess else {
                throw IOKitHardwareConfiguratorError.reportWriteFailed(
                    index: assignment.index,
                    code: writeResult
                )
            }

            if offset < preparedReports.count - 1 {
                Thread.sleep(forTimeInterval: packetDelay)
            }
        }
    }

    private func report(for assignment: IndexedControlBinding) throws -> [UInt8] {
        let nativeAction: NativeHardwareAction
        switch assignment.binding {
        case let .preset(action):
            // App-only actions have no firmware representation. Write an empty
            // slot so the rest of the six offline keys still sync (the FN/
            // voice key can never work offline anyway — hardware limitation).
            nativeAction = action.isAppOnly
                ? .none
                : PresetNativeShortcutResolver.resolve(action)
        case let .shortcut(shortcut):
            nativeAction = .shortcut(shortcut)
        }

        switch nativeAction {
        case .none:
            let emptyShortcut = try NativeShortcut(entries: [], displayName: "不做事")
            return try VibeKeyPacketCodec.shortcutReport(
                index: assignment.index,
                shortcut: emptyShortcut
            )
        case let .shortcut(shortcut):
            return try VibeKeyPacketCodec.shortcutReport(
                index: assignment.index,
                shortcut: shortcut
            )
        case let .fixedFunction(functionCode):
            return try VibeKeyPacketCodec.fixedFunctionReport(
                index: assignment.index,
                functionCode: functionCode
            )
        case .unsupported:
            throw IOKitHardwareConfiguratorError.unsupportedAction(
                control: assignment.control,
                actionName: assignment.binding.displayName
            )
        }
    }
}
