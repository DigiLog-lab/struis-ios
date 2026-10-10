#import "NativeMemory.h"
#import <mach/mach.h>
#import <os/proc.h>
#import <time.h>
#import <unistd.h>

NSDictionary<NSString *, NSNumber *> *StruisMemorySnapshot(void) {
    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    result[@"pid"] = @(getpid());
    struct timespec timestamp = {0};
    int clockStatus = clock_gettime(CLOCK_MONOTONIC, &timestamp);
    result[@"clockStatus"] = @(clockStatus);
    if (clockStatus == 0) {
        result[@"monotonicNanoseconds"] = @((uint64_t)timestamp.tv_sec * 1000000000ULL + (uint64_t)timestamp.tv_nsec);
    }
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO,
                                    (task_info_t)&info, &count);
    result[@"queryStatus"] = @(status);
    result[@"queryCount"] = @(count);
    if (status == KERN_SUCCESS && count >= TASK_VM_INFO_REV1_COUNT) {
        result[@"footprint"] = @(info.phys_footprint);
    }
#ifdef TASK_VM_INFO_REV3_COUNT
    // Kernel ledger lifetime maximum for this process, not a phase-specific peak.
    if (status == KERN_SUCCESS && count >= TASK_VM_INFO_REV3_COUNT && info.ledger_phys_footprint_peak >= 0) {
        result[@"lifetimePeak"] = @((uint64_t)info.ledger_phys_footprint_peak);
    }
#endif
    // Zero is a valid available-memory reading. It is never a promised limit.
    result[@"available"] = @(os_proc_available_memory());
    return result;
}
