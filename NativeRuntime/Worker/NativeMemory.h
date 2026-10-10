#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Numeric diagnostics only. Failed/unsupported measurements are omitted, not zero.
/// CLOCK_MONOTONIC timestamps use nanoseconds; lifetimePeak is OS process lifetime
/// physical-footprint high-water, never a representative-phase or exit measurement.
NSDictionary<NSString *, NSNumber *> *StruisMemorySnapshot(void);
NS_ASSUME_NONNULL_END
