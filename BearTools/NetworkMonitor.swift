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
    // MARK: - 属性
    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bear.network.monitor")
    private let cellularData = CTCellularData()
    private let telephonyNetworkInfo = CTTelephonyNetworkInfo()
    
    // MARK: - 使用 Combine 发布网络状态
    private let _networkStatus = CurrentValueSubject<NetworkStatus, Never>(.unknown)
    private let _cellularDetails = CurrentValueSubject<CellularDetails?, Never>(nil)
    private let _isNetworkAvailable = CurrentValueSubject<Bool, Never>(false)
    private let _isUsingVPN = CurrentValueSubject<Bool, Never>(false)

    // MARK: - 公开的信号接口
    /// 网络状态信号
    var networkStatus: AnyPublisher<NetworkStatus, Never> {
        _networkStatus.eraseToAnyPublisher()
    }
    
    /// 蜂窝网络详情信号
    var cellularDetails: AnyPublisher<CellularDetails?, Never> {
        _cellularDetails.eraseToAnyPublisher()
    }
    
    /// 网络是否可用信号
    var isNetworkAvailable: AnyPublisher<Bool, Never> {
        _isNetworkAvailable.eraseToAnyPublisher()
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
    
    // MARK: - 网络状态枚举
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
    }
    
    enum CellularGeneration: Equatable {
        case g2, g3, g4, g5, lteAdvanced, unknown
        
        var description: String {
            switch self {
            case .g2: return "2G"
            case .g3: return "3G"
            case .g4: return "4G"
            case .g5: return "5G"
            case .lteAdvanced: return "LTE Advanced"
            case .unknown: return "未知"
            }
        }
        
        var displayName: String {
            description
        }
    }
    
    // MARK: - 蜂窝网络详情结构
    struct CellularDetails: Equatable {
        let generation: CellularGeneration
        let carrierName: String?
        let mobileCountryCode: String?
        let mobileNetworkCode: String?
        let radioAccessTechnology: String?
        let signalStrength: Int?
        
        static func == (lhs: CellularDetails, rhs: CellularDetails) -> Bool {
            return lhs.generation == rhs.generation &&
                   lhs.carrierName == rhs.carrierName
        }
    }
    
    // MARK: - 组合信号
    /// 完整的网络信息信号
    var fullNetworkInfo: AnyPublisher<(status: NetworkStatus, details: CellularDetails?, available: Bool), Never> {
        Publishers.CombineLatest3(
            _networkStatus.removeDuplicates(),
            _cellularDetails,
            _isNetworkAvailable.removeDuplicates()
        )
        .map { (status, details, available) in
            (status: status, details: details, available: available)  // 添加标签
        }
        .eraseToAnyPublisher()
    }
    
    /// 网络类型变化信号
    var networkTypeChanged: AnyPublisher<NetworkStatus, Never> {
        _networkStatus
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    var vpnStatusChanged: AnyPublisher<Bool, Never> {
        _isUsingVPN
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    /// 当网络可用时的信号
    var whenNetworkAvailable: AnyPublisher<NetworkStatus, Never> {
        _networkStatus
            .combineLatest(_isNetworkAvailable)
            .filter { $0.1 }
            .map { $0.0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    // MARK: - 初始化
    init() {
        cellularData.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .restricted:
                    print("[NetworkMonitor] 蜂窝数据访问受限")
                case .notRestricted:
                    print("[NetworkMonitor] 蜂窝数据访问正常")
                case .restrictedStateUnknown:
                    print("[NetworkMonitor] 蜂窝数据访问状态未知")
                @unknown default:
                    break
                }
            }
        }
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - 检查是否使用VPN
    var isUsingVPN: Bool {
        pathMonitor.currentPath.usesInterfaceType(.other)
    }
    
    // MARK: - 开始监控
    func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor.start(queue: queue)
        handlePathUpdate(pathMonitor.currentPath)
    }
    
    // MARK: - 停止监控
    func stopMonitoring() {
        pathMonitor.cancel()
    }
    
    // MARK: - 处理网络路径更新
    private func handlePathUpdate(_ path: NWPath) {
        let oldStatus = _networkStatus.value
        let newStatus = determineNetworkStatus(from: path)
        let isAvailable = path.status == .satisfied
        _networkStatus.send(newStatus)
        _isNetworkAvailable.send(isAvailable)
        _isUsingVPN.send(isUsingVPN)
        if case .cellular = newStatus {
            updateCellularDetails()
        } else {
            _cellularDetails.send(nil)
        }
        if oldStatus != newStatus {
            print("[NetworkMonitor] 网络状态变化: \(oldStatus.description) -> \(newStatus.description)")
        }
    }
    
    // MARK: - 确定网络状态
    private func determineNetworkStatus(from path: NWPath) -> NetworkStatus {
        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wifi) {
                return .wifi
            } else if path.usesInterfaceType(.cellular) {
                let generation = getCurrentCellularGeneration()
                return .cellular(generation)
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
    
    // MARK: - 获取当前蜂窝网络代际
    private func getCurrentCellularGeneration() -> CellularGeneration {
        guard let currentRadioTech = telephonyNetworkInfo.serviceCurrentRadioAccessTechnology else {
            return .unknown
        }
        if let radioTech = currentRadioTech.values.first {
            return cellularGeneration(from: radioTech)
        }
        return .unknown
    }
    
    // MARK: - 从 Radio Access Technology 转换为代际
    private func cellularGeneration(from radioTech: String) -> CellularGeneration {
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
    
    // MARK: - 更新蜂窝网络详情
    private func updateCellularDetails() {
        let generation = getCurrentCellularGeneration()
        let providers = telephonyNetworkInfo.serviceSubscriberCellularProviders
        let carrier = providers?.values.first
        let radioTech = telephonyNetworkInfo.serviceCurrentRadioAccessTechnology?.values.first
        let details = CellularDetails(
            generation: generation,
            carrierName: carrier?.carrierName,
            mobileCountryCode: carrier?.mobileCountryCode,
            mobileNetworkCode: carrier?.mobileNetworkCode,
            radioAccessTechnology: radioTech,
            signalStrength: nil
        )
        _cellularDetails.send(details)
    }
    
}

// MARK: - NetworkStatus 扩展
extension NetworkMonitor.NetworkStatus {
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

// MARK: - CellularGeneration 扩展
extension NetworkMonitor.CellularGeneration {
    /// 是否为低速网络
    var isSlowNetwork: Bool {
        switch self {
        case .g2, .g3:
            return true
        case .g4, .g5, .lteAdvanced, .unknown:
            return false
        }
    }
    
    /// 是否为高速网络
    var isHighSpeedNetwork: Bool {
        switch self {
        case .g4, .g5, .lteAdvanced:
            return true
        case .g2, .g3, .unknown:
            return false
        }
    }
    
    /// 获取网络质量等级
    var qualityLevel: Int {
        switch self {
        case .g2: return 1
        case .g3: return 2
        case .g4, .lteAdvanced: return 3
        case .g5: return 4
        case .unknown: return 0
        }
    }
}

// MARK: - 网络优化工具
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
            case .g4, .lteAdvanced:
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
            case .g4, .lteAdvanced:
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
