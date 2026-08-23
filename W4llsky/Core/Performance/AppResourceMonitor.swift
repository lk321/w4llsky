//
//  AppResourceMonitor.swift
//  W4llsky
//
//  Self CPU%/memory via mach task/thread info. Sampled on demand only
//  (menu open) — never a running timer, so it costs nothing while unused.
//

import Darwin
import Foundation

final class AppResourceMonitor {
    struct Snapshot {
        let cpuPercent: Double
        let memoryMB: Double
    }

    private var previousCPUTime: Double = 0
    private var previousSampleTime = Date()

    func sample() -> Snapshot {
        let memoryMB = residentMemoryMB()
        let cpuTime = totalCPUTimeSeconds()

        let now = Date()
        let elapsed = now.timeIntervalSince(previousSampleTime)
        let cpuPercent = elapsed > 0 ? max(0, min(100, ((cpuTime - previousCPUTime) / elapsed) * 100)) : 0

        previousCPUTime = cpuTime
        previousSampleTime = now

        return Snapshot(cpuPercent: cpuPercent, memoryMB: memoryMB)
    }

    private func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    private func totalCPUTimeSeconds() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList else {
            return previousCPUTime
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size)
            )
        }

        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            total += Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        }
        return total
    }
}
