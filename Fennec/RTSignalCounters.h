#ifndef RTSignalCounters_h
#define RTSignalCounters_h

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CGRTSignalCounters CGRTSignalCounters;

CGRTSignalCounters * _Nullable CGRTSignalCountersCreate(void);
void CGRTSignalCountersDestroy(CGRTSignalCounters * _Nullable counters);

void CGRTSignalCountersDrain(
    CGRTSignalCounters * _Nonnull counters,
    uint64_t * _Nonnull overloadCount,
    uint64_t * _Nonnull abnormalStopCount,
    uint64_t * _Nonnull defaultOutputChangeCount,
    uint64_t * _Nonnull sampleRateChangeCount,
    uint64_t * _Nonnull deviceStateChangeCount,
    uint64_t * _Nonnull serviceRestartCount
);

OSStatus CGAudioAddPropertyListener(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element,
    CGRTSignalCounters * _Nonnull counters
);

OSStatus CGAudioRemovePropertyListener(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element,
    CGRTSignalCounters * _Nonnull counters
);

#ifdef __cplusplus
}
#endif

#endif /* RTSignalCounters_h */
