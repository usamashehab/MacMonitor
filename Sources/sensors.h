#ifndef SENSORS_H
#define SENSORS_H
#include <CoreFoundation/CoreFoundation.h>

/// `names` must hold max*64 bytes (one 64-byte C string per sensor). Fills names/values with up to `max` temperature sensors (°C). Returns count.
int mm_read_temperatures(char *names, double *values, int max);

/// GPU utilisation 0-100 from IOAccelerator PerformanceStatistics, -1 if unavailable.
double mm_gpu_utilization(void);
#endif
