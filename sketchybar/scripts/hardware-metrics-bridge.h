#ifndef HARDWARE_METRICS_BRIDGE_H
#define HARDWARE_METRICS_BRIDGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// IOReport is a read-only private property contract. Keep this bridge limited to
// channel discovery, subscriptions, samples, and sample inspection. The macOS 15
// libIOReport ABI exports no subscription release or destroy function.
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

CFDictionaryRef IOReportCopyChannelsInGroup(
    CFStringRef group,
    CFStringRef subgroup,
    uint64_t options_a,
    uint64_t options_b,
    uint64_t options_c
);
void IOReportMergeChannels(
    CFDictionaryRef destination,
    CFDictionaryRef source,
    CFTypeRef options
);
IOReportSubscriptionRef IOReportCreateSubscription(
    void *allocator,
    CFMutableDictionaryRef channels,
    CFMutableDictionaryRef *subscribed_channels,
    uint64_t options,
    CFTypeRef context
);
CFDictionaryRef IOReportCreateSamples(
    IOReportSubscriptionRef subscription,
    CFMutableDictionaryRef channels,
    CFTypeRef options
);
CFDictionaryRef IOReportCreateSamplesDelta(
    CFDictionaryRef first,
    CFDictionaryRef second,
    CFTypeRef options
);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);
int32_t IOReportStateGetCount(CFDictionaryRef channel);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index);
int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);

#endif
