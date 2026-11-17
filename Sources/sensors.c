#include "sensors.h"
#include <IOKit/IOKitLib.h>

// Private IOHIDEventSystem API (used by powermetrics/Stats etc. on Apple Silicon).
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

#define kTempType 15
#define kTempField (kTempType << 16)

static IOHIDEventSystemClientRef client = NULL;

int mm_read_temperatures(char *names, double *values, int max) {
    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) return 0;
        int page = 0xff00, usage = 5;
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *vals[] = { p, u };
        CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(client, match);
        CFRelease(match); CFRelease(p); CFRelease(u);
    }
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;
    int n = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && n < max; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kTempType, 0, 0);
        if (!ev) continue;
        double t = IOHIDEventGetFloatValue(ev, kTempField);
        CFRelease(ev);
        CFTypeRef name = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        char *dst = names + n * 64; dst[0] = 0;
        if (name) {
            if (CFGetTypeID(name) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)name, dst, 64, kCFStringEncodingUTF8);
            CFRelease(name);
        }
        if (t > 0 && t < 150) values[n++] = t;
    }
    CFRelease(services);
    return n;
}

double mm_gpu_utilization(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS)
        return -1;
    double best = -1;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        CFDictionaryRef stats = IORegistryEntryCreateCFProperty(e, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (stats) {
            CFNumberRef v = CFDictionaryGetValue(stats, CFSTR("Device Utilization %"));
            if (!v) v = CFDictionaryGetValue(stats, CFSTR("GPU Activity(%)"));
            int64_t x;
            if (v && CFNumberGetValue(v, kCFNumberSInt64Type, &x) && x > best) best = (double)x;
            CFRelease(stats);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return best;
}
