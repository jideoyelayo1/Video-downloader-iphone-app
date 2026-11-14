import Foundation
import Network

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
