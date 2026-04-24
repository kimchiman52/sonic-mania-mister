#ifndef SONIC_MANIA_CORE_CONTEXT_H
#define SONIC_MANIA_CORE_CONTEXT_H

#include <stddef.h>

int sonicmania_core_context_init(const char *rbf_path, char *error, size_t error_size);
const char *sonicmania_core_context_core_name();

#endif
