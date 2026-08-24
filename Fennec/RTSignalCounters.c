#include "RTSignalCounters.h"
#include <stdatomic.h>
#include <stdlib.h>

struct CGRTSignalCounters {
    _Atomic(uint64_t) overloads;
    _Atomic(uint64_t) abnormalStops;
    _Atomic(uint64_t) defaultOutputChanges;
    _Atomic(uint64_t) sampleRateChanges;
    _Atomic(uint64_t) deviceStateChanges;
    _Atomic(uint64_t) serviceRestarts;
};

static OSStatus CGAudioPropertyListener(
    AudioObjectID objectID,
    UInt32 numberAddresses,
    const AudioObjectPropertyAddress addresses[],
    void *clientData
) {
    (void)objectID;
    CGRTSignalCounters *counters = (CGRTSignalCounters *)clientData;
    if (counters == NULL || addresses == NULL) {
        return noErr;
    }

    for (UInt32 index = 0; index < numberAddresses; index++) {
        switch (addresses[index].mSelector) {
            case kAudioDeviceProcessorOverload:
                atomic_fetch_add_explicit(&counters->overloads, 1, memory_order_relaxed);
                break;
            case kAudioDevicePropertyIOStoppedAbnormally:
                atomic_fetch_add_explicit(&counters->abnormalStops, 1, memory_order_relaxed);
                break;
            case kAudioHardwarePropertyDefaultOutputDevice:
                atomic_fetch_add_explicit(&counters->defaultOutputChanges, 1, memory_order_relaxed);
                break;
            case kAudioDevicePropertyNominalSampleRate:
                atomic_fetch_add_explicit(&counters->sampleRateChanges, 1, memory_order_relaxed);
                break;
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceHasChanged:
                atomic_fetch_add_explicit(&counters->deviceStateChanges, 1, memory_order_relaxed);
                break;
            case kAudioHardwarePropertyServiceRestarted:
                atomic_fetch_add_explicit(&counters->serviceRestarts, 1, memory_order_relaxed);
                break;
            default:
                break;
        }
    }

    return noErr;
}

CGRTSignalCounters *CGRTSignalCountersCreate(void) {
    CGRTSignalCounters *counters = calloc(1, sizeof(CGRTSignalCounters));
    if (counters == NULL) {
        return NULL;
    }

    atomic_init(&counters->overloads, 0);
    atomic_init(&counters->abnormalStops, 0);
    atomic_init(&counters->defaultOutputChanges, 0);
    atomic_init(&counters->sampleRateChanges, 0);
    atomic_init(&counters->deviceStateChanges, 0);
    atomic_init(&counters->serviceRestarts, 0);
    return counters;
}

void CGRTSignalCountersDestroy(CGRTSignalCounters *counters) {
    free(counters);
}

void CGRTSignalCountersDrain(
    CGRTSignalCounters *counters,
    uint64_t *overloadCount,
    uint64_t *abnormalStopCount,
    uint64_t *defaultOutputChangeCount,
    uint64_t *sampleRateChangeCount,
    uint64_t *deviceStateChangeCount,
    uint64_t *serviceRestartCount
) {
    if (counters == NULL) {
        return;
    }

    *overloadCount = atomic_exchange_explicit(&counters->overloads, 0, memory_order_relaxed);
    *abnormalStopCount = atomic_exchange_explicit(&counters->abnormalStops, 0, memory_order_relaxed);
    *defaultOutputChangeCount = atomic_exchange_explicit(&counters->defaultOutputChanges, 0, memory_order_relaxed);
    *sampleRateChangeCount = atomic_exchange_explicit(&counters->sampleRateChanges, 0, memory_order_relaxed);
    *deviceStateChangeCount = atomic_exchange_explicit(&counters->deviceStateChanges, 0, memory_order_relaxed);
    *serviceRestartCount = atomic_exchange_explicit(&counters->serviceRestarts, 0, memory_order_relaxed);
}

OSStatus CGAudioAddPropertyListener(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element,
    CGRTSignalCounters *counters
) {
    AudioObjectPropertyAddress address = { selector, scope, element };
    return AudioObjectAddPropertyListener(objectID, &address, CGAudioPropertyListener, counters);
}

OSStatus CGAudioRemovePropertyListener(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element,
    CGRTSignalCounters *counters
) {
    AudioObjectPropertyAddress address = { selector, scope, element };
    return AudioObjectRemovePropertyListener(objectID, &address, CGAudioPropertyListener, counters);
}
