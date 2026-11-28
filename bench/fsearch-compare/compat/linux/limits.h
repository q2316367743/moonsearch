#pragma once

/* FSearch includes <linux/limits.h> for PATH_MAX/NAME_MAX.  macOS has the
 * same limits in <limits.h>, so this shim lets the core library compile
 * outside Linux. */

#include <limits.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#ifndef NAME_MAX
#define NAME_MAX 255
#endif
