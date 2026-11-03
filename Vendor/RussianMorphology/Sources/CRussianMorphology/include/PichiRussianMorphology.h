#ifndef PICHI_RUSSIAN_MORPHOLOGY_H
#define PICHI_RUSSIAN_MORPHOLOGY_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Returns 1 for a complete paradigm, 0 for an unknown word, or a negative error.
// A negative result never represents a usable partial paradigm. Output is a
// sequence of UTF-8, NUL-terminated words; written includes all terminators.
int pichi_russian_word_forms(const char *word, size_t word_length,
                            char *output, size_t capacity,
                            size_t *written, size_t *form_count);
#ifdef __cplusplus
}
#endif
#endif
