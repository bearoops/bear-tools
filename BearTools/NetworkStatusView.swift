//
//  NetworkStatusView.swift
//  BearTools
//
//  Created by issuser on 2026/3/25.
//

import SwiftUI
import Combine

class NetworkViewModel: ObservableObject {
    
    @Published var networkStatus: NetworkMonitor.NetworkStatus = .unknown
    @Published var isOnline: Bool = false
    @Published var networkQuality: String = ""
    
    private let networkMonitor = NetworkMonitor()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // 订阅网络状态
        networkMonitor.networkStatusChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] changed in
                self?.networkStatus = changed.new
                self?.updateNetworkQuality(changed.new)
                self?.isOnline = changed.new.isAvailable
            }
            .store(in: &cancellables)
        demoUsage()
    }
    
    private func updateNetworkQuality(_ status: NetworkMonitor.NetworkStatus) {
        switch status {
        case .cellular(let generation):
            switch generation {
            case .g2:
                networkQuality = "低速网络 (2G)"
            case .g3:
                networkQuality = "中速网络 (3G)"
            case .g4:
                networkQuality = "高速网络 (4G)"
            case .g5:
                networkQuality = "超高速网络 (5G)"
            case .unknown:
                networkQuality = "未知网络质量"
            }
        case .wifi:
            networkQuality = "Wi-Fi 网络"
        case .unavailable:
            networkQuality = "无网络"
        case .unknown:
            networkQuality = "网络状态未知"
        }
    }
    
    func demoUsage() {
        // 订阅网络状态变化
        networkMonitor.networkStatusChanged
            .sink { (oldStatus, newStatus) in
                print("网络状态从 \(oldStatus.description) 变为 \(newStatus.description)")
                // 根据网络变化调整应用行为
                switch newStatus {
                case .unavailable:
                    // 显示离线模式
                    break
                case .wifi:
                    // 开始同步数据
                    break
                case .cellular(let generation):
                    switch generation {
                    case .g2, .g3:
                        print("网络较慢 (\(generation.description))，启用低质量模式")
                    case .g4, .g5:
                        print("高速网络 (\(generation.description))，可进行高质量传输")
                    case .unknown:
                        print("未知蜂窝网络")
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
        // 订阅蜂窝网络详情
        networkMonitor.cellularDetailsChanged
            .compactMap { $0.new }
            .sink { details in
                print("蜂窝网络: \(details.generation.description)")
            }
            .store(in: &cancellables)
        networkMonitor.vpnStatusChanged
            .sink { isVPN in
                print("isUsingVPN: \(isVPN)")
            }
            .store(in: &cancellables)
    }
    
}

struct NetworkStatusView: View {
    @StateObject private var viewModel = NetworkViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            // 网络状态指示器
            HStack {
                Circle()
                    .fill(viewModel.isOnline ?
                          (viewModel.networkStatus.isWifi ? Color.blue : Color.green)
                          : Color.red)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading) {
                    Text(viewModel.networkStatus.description)
                        .font(.headline)
                    Text(viewModel.networkQuality)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.isOnline {
                    Text("在线")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("离线")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            // 网络优化建议
            if case .cellular(let generation) = viewModel.networkStatus {
                cellularView(generation)
            }
        }
        .padding()
    }
    
    @ViewBuilder
    func cellularView(_ generation: NetworkMonitor.CellularGeneration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网络优化建议")
                .font(.subheadline)
                .bold()
                .foregroundColor(.blue)
            switch generation {
            case .g2, .g3:
                Text("• 网络较慢，建议开启低流量模式")
                Text("• 避免观看高清视频")
                Text("• 优先使用文字聊天")
            case .g4:
                Text("• 可正常观看标清视频")
                Text("• 适合图片浏览和文件下载")
            case .g5:
                Text("• 可观看4K超高清视频")
                Text("• 支持高速文件传输和实时游戏")
            case .unknown:
                Text("• 网络状态未知，请检查网络连接")
            }
        }
        .font(.caption)
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
}
