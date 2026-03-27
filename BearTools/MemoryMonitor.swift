//
//  MemoryMonitor.swift
//  SailOptTools
//
//  Created by 小熊 on 2025/10/14.
//

import Foundation
import MachO

public class MemoryMonitor {
    // 当前App内存使用 (字节)
    public static func currentAppMemoryUsage() -> Int64 {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Int64(taskInfo.phys_footprint)
        }
        return 0
    }
    
    // 系统可用内存 (字节)
    public static func availableSystemMemory() -> Int64 {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let pageSize = Int64(vm_kernel_page_size)
            let freePages = Int64(vmStats.free_count)
            let inactivePages = Int64(vmStats.inactive_count)
            return pageSize * (freePages + inactivePages)
        }
        return 0
    }
    
    // 系统总内存 (字节)
    public static func totalSystemMemory() -> Int64 {
        return Int64(ProcessInfo.processInfo.physicalMemory)
    }
    
    // 内存使用百分比 (0.0 ~ 1.0)
    public static func memoryUsagePercentage() -> Float {
        let used = currentAppMemoryUsage()
        let total = totalSystemMemory()
        
        guard total > 0 else { return 0.0 }
        return Float(used) / Float(total)
    }
    
    // 格式化输出辅助方法
    public static func formattedMemory(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: bytes)
    }
}
