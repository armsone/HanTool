import SwiftUI
import Darwin

/// Monitors real Darwin network interface byte rates (upload and download)
/// for physical en-prefixed interfaces (Ethernet / Wi-Fi) avoiding VPN tunnel double counts.
@MainActor
final class NetworkRateMonitor: ObservableObject {
    @Published var uploadRate: Double = 0
    @Published var downloadRate: Double = 0

    private struct InterfaceSample {
        let ibytes: UInt64
        let obytes: UInt64
        let timestamp: UInt64 // mach_continuous_time
    }

    private var previousSamples: [String: InterfaceSample] = [:]
    private var hasSampledOnce = false

    /// Samples interface counters using `getifaddrs` filtering for AF_LINK and en* interfaces.
    func sample() {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else {
            return
        }
        defer { freeifaddrs(ifap) }

        var currentSamples: [String: (ibytes: UInt64, obytes: UInt64)] = [:]
        let now = mach_continuous_time()

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            let isUpAndRunning = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0

            if isUpAndRunning, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") {
                    if let data = ifa.ifa_data {
                        let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                        let ibytes = UInt64(networkData.ifi_ibytes)
                        let obytes = UInt64(networkData.ifi_obytes)
                        currentSamples[name] = (ibytes, obytes)
                    }
                }
            }
            cursor = ifa.ifa_next
        }

        guard hasSampledOnce else {
            for (name, counts) in currentSamples {
                previousSamples[name] = InterfaceSample(ibytes: counts.ibytes, obytes: counts.obytes, timestamp: now)
            }
            hasSampledOnce = true
            return
        }

        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)

        var totalDeltaIn: Double = 0
        var totalDeltaOut: Double = 0
        var maxTimeDeltaSec: Double = 0

        for (name, counts) in currentSamples {
            if let prev = previousSamples[name] {
                // Check for counter reset / overflow
                if counts.ibytes >= prev.ibytes && counts.obytes >= prev.obytes && now > prev.timestamp {
                    let elapsedMach = now - prev.timestamp
                    let elapsedNano = Double(elapsedMach * UInt64(timebaseInfo.numer)) / Double(timebaseInfo.denom)
                    let elapsedSec = elapsedNano / 1_000_000_000.0

                    if elapsedSec > 0 {
                        let deltaIn = Double(counts.ibytes - prev.ibytes) / elapsedSec
                        let deltaOut = Double(counts.obytes - prev.obytes) / elapsedSec

                        totalDeltaIn += deltaIn
                        totalDeltaOut += deltaOut
                        if elapsedSec > maxTimeDeltaSec {
                            maxTimeDeltaSec = elapsedSec
                        }
                    }
                }
            }
            // Update tracking
            previousSamples[name] = InterfaceSample(ibytes: counts.ibytes, obytes: counts.obytes, timestamp: now)
        }

        // Clean up interfaces no longer present
        let currentKeys = Set(currentSamples.keys)
        previousSamples = previousSamples.filter { currentKeys.contains($0.key) }

        self.downloadRate = totalDeltaIn
        self.uploadRate = totalDeltaOut
    }
}

/// Compact two-stacked-rows indicator displaying current network rate (Upload / Download).
/// Red dot upload above blue dot download, monospaced digits, stable width, adaptive theme.
struct NetworkRateIndicator: View {
    @StateObject private var monitor = NetworkRateMonitor()
    @Environment(\.bkPalette) private var palette

    var body: some View {
        let upload = formatRate(monitor.uploadRate)
        let download = formatRate(monitor.downloadRate)

        VStack(alignment: .leading, spacing: 1) {
            rateRow(
                color: .red,
                rate: upload,
                label: "업로드"
            )
            rateRow(
                color: .blue,
                rate: download,
                label: "다운로드"
            )
        }
        .frame(width: 68, alignment: .leading)
        .help("네트워크 전송률 (Mac 이더넷/Wi-Fi 전체 합산, VPN 제외)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Mac 이더넷 및 Wi-Fi 전체 네트워크 속도: 업로드 \(upload.value) \(upload.unit), 다운로드 \(download.value) \(download.unit)"
        )
        .task {
            // Sample periodically while active; automatically cancelled when offscreen.
            while !Task.isCancelled {
                monitor.sample()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private func rateRow(color: Color, rate: (value: String, unit: String), label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)

            Text(rate.value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(palette.text2Color)
                .lineLimit(1)
                .frame(width: 31, alignment: .trailing)

            Text(rate.unit)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(palette.text2Color)
                .lineLimit(1)
                .frame(width: 23, alignment: .leading)
        }
        .accessibilityLabel("\(label): \(rate.value) \(rate.unit)")
    }

    private func formatRate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        guard bytesPerSecond > 0 else { return ("0", "B/s") }

        if bytesPerSecond < 1024 {
            return (String(format: "%.0f", bytesPerSecond), "B/s")
        } else if bytesPerSecond < 1024 * 1024 {
            let kb = bytesPerSecond / 1024.0
            if kb < 100 {
                return (String(format: "%.1f", kb), "KB/s")
            } else {
                return (String(format: "%.0f", kb), "KB/s")
            }
        } else if bytesPerSecond < 1024 * 1024 * 1024 {
            let mb = bytesPerSecond / (1024.0 * 1024.0)
            if mb < 100 {
                return (String(format: "%.1f", mb), "MB/s")
            } else {
                return (String(format: "%.0f", mb), "MB/s")
            }
        } else {
            let gb = bytesPerSecond / (1024.0 * 1024.0 * 1024.0)
            return (String(format: "%.2f", gb), "GB/s")
        }
    }
}
