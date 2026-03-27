//
//  NetworkMonitor.swift
//  BearTools
//
//  Created by issuser on 2026/3/25.
//

import Network
import CoreTelephony
import Combine

class NetworkMonitor {

    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bear.network.monitor")
    private let telephonyNetworkInfo = CTTelephonyNetworkInfo()
    
    private let _networkStatus = CurrentValueSubject<NetworkStatus, Never>(.unknown)
    private let _cellularDetails = CurrentValueSubject<CellularDetails?, Never>(nil)
    private let _isUsingVPN = CurrentValueSubject<Bool, Never>(false)
    
    init() {
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    /// 网络状态信号
    var networkStatus: NetworkStatus {
        _networkStatus.value
    }
    
    /// 蜂窝网络详情信号
    var cellularDetails: CellularDetails? {
        _cellularDetails.value
    }
    
    var isUsingVPN: Bool {
        _isUsingVPN.value
    }
    
    // MARK: - 公开的信号接口
    
    /// 完整的网络信息信号
    var networkInfoChanged: AnyPublisher<(status: NetworkStatus, details: CellularDetails?, isVPN: Bool), Never> {
        Publishers.CombineLatest3(
            _networkStatus.removeDuplicates(),
            _cellularDetails.removeDuplicates(),
            _isUsingVPN.removeDuplicates()
        )
        .map { ($0, $1, $2) }
        .eraseToAnyPublisher()
    }
    
    /// 网络状态变化信号（包含新旧值）
    var networkStatusChanged: AnyPublisher<(old: NetworkStatus, new: NetworkStatus), Never> {
        _networkStatus
            .removeDuplicates()
            .scan((.unknown, .unknown)) { previous, current in
                (previous.1, current)
            }
            .dropFirst()
            .eraseToAnyPublisher()
    }
    
    var cellularDetailsChanged: AnyPublisher<(old: CellularDetails?, new: CellularDetails?), Never> {
        _cellularDetails
            .removeDuplicates()
            .scan((nil, nil)) { previous, current in
                (previous.1, current)
            }
            .dropFirst()
            .eraseToAnyPublisher()
    }
    
    var vpnStatusChanged: AnyPublisher<Bool, Never> {
        _isUsingVPN
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor.start(queue: queue)
        handlePathUpdate(pathMonitor.currentPath)
    }
    
    func stopMonitoring() {
        pathMonitor.cancel()
    }
    
    private func handlePathUpdate(_ path: NWPath) {
        let oldStatus = _networkStatus.value
        let newStatus = determineNetworkStatus(from: path)
        _networkStatus.send(newStatus)
        let isVPN = path.usesInterfaceType(.other)
        _isUsingVPN.send(isVPN)
        let details = CellularDetails(info: telephonyNetworkInfo)
        _cellularDetails.send(details)
        if oldStatus != newStatus {
            print("[NetworkMonitor] 网络状态变化: \(oldStatus.description) -> \(newStatus.description)")
        }
    }
    
    private func determineNetworkStatus(from path: NWPath) -> NetworkStatus {
        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wifi) {
                return .wifi
            } else if path.usesInterfaceType(.cellular) {
                let details = CellularDetails(info: telephonyNetworkInfo)
                return .cellular(details.generation)
            } else if path.usesInterfaceType(.wiredEthernet) {
                return .wifi
            } else {
                return .unknown
            }
        case .unsatisfied, .requiresConnection:
            return .unavailable
        @unknown default:
            return .unknown
        }
    }
    
}

extension NetworkMonitor {
    
    enum NetworkStatus: Equatable {
        case unavailable
        case wifi
        case cellular(CellularGeneration)
        case unknown
        
        static func == (lhs: NetworkStatus, rhs: NetworkStatus) -> Bool {
            switch (lhs, rhs) {
            case (.unavailable, .unavailable),
                 (.wifi, .wifi),
                 (.unknown, .unknown):
                return true
            case (.cellular(let lhsType), .cellular(let rhsType)):
                return lhsType == rhsType
            default:
                return false
            }
        }
        
        var description: String {
            switch self {
            case .unavailable:
                return "网络不可用"
            case .wifi:
                return "Wi-Fi"
            case .cellular(let generation):
                return "蜂窝网络(\(generation.description))"
            case .unknown:
                return "未知"
            }
        }
        
        var isAvailable: Bool {
            switch self {
            case .wifi, .cellular(_):
                return true
            default:
                return false
            }
        }
        
        var isCellular: Bool {
            if case .cellular = self {
                return true
            }
            return false
        }
        
        var isWifi: Bool {
            return self == .wifi
        }
    }
    
    enum CellularGeneration: Equatable {
        case unknown, g2, g3, g4, g5
        
        var description: String {
            switch self {
            case .unknown: return ""
            case .g2: return "2G"
            case .g3: return "3G"
            case .g4: return "4G"
            case .g5: return "5G"
            }
        }
        
        var displayName: String {
            description
        }
        
        /// 是否为低速网络
        var isSlowNetwork: Bool {
            switch self {
            case .g2, .g3:
                return true
            case .g4, .g5, .unknown:
                return false
            }
        }
        
        /// 是否为高速网络
        var isHighSpeedNetwork: Bool {
            switch self {
            case .g4, .g5:
                return true
            case .g2, .g3, .unknown:
                return false
            }
        }
    }
    
    // 蜂窝网络详情结构
    struct CellularDetails: Equatable {
        let generation: CellularGeneration
        let radioAccessTechnology: String?
        
        init(info: CTTelephonyNetworkInfo?) {
            if let currentRadioTech = info?.serviceCurrentRadioAccessTechnology,
                let radioTech = currentRadioTech.values.first {
                self.generation = Self.generation(from: radioTech)
                self.radioAccessTechnology = radioTech
            } else {
                self.generation = .unknown
                self.radioAccessTechnology = nil
            }
        }
        
        static func generation(from radioTech: String) -> CellularGeneration {
            switch radioTech {
            case CTRadioAccessTechnologyGPRS,
                 CTRadioAccessTechnologyEdge,
                 CTRadioAccessTechnologyCDMA1x:
                return .g2
            case CTRadioAccessTechnologyWCDMA,
                 CTRadioAccessTechnologyHSDPA,
                 CTRadioAccessTechnologyHSUPA,
                 CTRadioAccessTechnologyCDMAEVDORev0,
                 CTRadioAccessTechnologyCDMAEVDORevA,
                 CTRadioAccessTechnologyCDMAEVDORevB,
                 CTRadioAccessTechnologyeHRPD:
                return .g3
            case CTRadioAccessTechnologyLTE:
                return .g4
            case CTRadioAccessTechnologyNRNSA,
                 CTRadioAccessTechnologyNR:
                return .g5
            default:
                return .unknown
            }
        }
        
        static func == (lhs: CellularDetails, rhs: CellularDetails) -> Bool {
            return lhs.radioAccessTechnology == rhs.radioAccessTechnology
        }
    }
    
}

// MARK: 网络优化工具
extension NetworkMonitor {
    /// 根据网络状态推荐最佳图片质量
    func recommendedImageQuality() -> ImageQuality {
        let status = _networkStatus.value
        
        switch status {
        case .wifi:
            return .high
        case .cellular(let generation):
            switch generation {
            case .g2, .g3:
                return .low
            case .g4:
                return .medium
            case .g5:
                return .high
            case .unknown:
                return .medium
            }
        case .unavailable, .unknown:
            return .low
        }
    }
    
    enum ImageQuality {
        case low, medium, high
        
        var compressionQuality: CGFloat {
            switch self {
            case .low: return 0.3
            case .medium: return 0.6
            case .high: return 0.9
            }
        }
    }
    
    /// 根据网络状态调整视频质量
    func recommendedVideoQuality() -> VideoQuality {
        let status = _networkStatus.value
        
        switch status {
        case .wifi:
            return .hd1080p
        case .cellular(let generation):
            switch generation {
            case .g2, .g3:
                return .low144p
            case .g4:
                return .sd480p
            case .g5:
                return .hd720p
            case .unknown:
                return .sd480p
            }
        case .unavailable, .unknown:
            return .low144p
        }
    }
    
    enum VideoQuality {
        case low144p, sd480p, hd720p, hd1080p
        
        var bitrate: Int {
            switch self {
            case .low144p: return 250_000
            case .sd480p: return 1_000_000
            case .hd720p: return 2_500_000
            case .hd1080p: return 5_000_000
            }
        }
    }
}
