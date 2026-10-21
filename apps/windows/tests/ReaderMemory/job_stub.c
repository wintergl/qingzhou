/* Isolated macOS probe: no Windows job, process, route or DNS API is called. */
#include <stddef.h>

void *CreateJobObjectW(void *attributes, const void *name)
{
    (void)attributes;
    (void)name;
    return NULL;
}
