#ifndef UTILS_H
#define UTILS_H

#include "ac.h"

char* load_file(const char* filename, long* length);
void load_patterns(AC_Machine* ac, const char* filename);

#endif