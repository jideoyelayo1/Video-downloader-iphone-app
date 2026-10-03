import Foundation
import Network

/// Whether the iPhone is on Wi-Fi, for "Waiting for Wi-Fi" when downloads are limited to it.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var isOnWiFi = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // A personal hotspot reached over Wi-Fi counts: it isn't this iPhone's mobile data.
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor [weak self] in self?.isOnWiFi = wifi }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
