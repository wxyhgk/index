/*
 * Thin C bridge for the Apache-2.0 AOSP PinyinIME decoder.
 * Index-specific wrapper; the upstream decoder remains in share/ unchanged.
 */
#ifndef INDEX_PINYIN_BRIDGE_H
#define INDEX_PINYIN_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool index_pinyin_open(const char *system_dictionary, const char *user_dictionary);
void index_pinyin_close(void);
void index_pinyin_reset(void);
size_t index_pinyin_search(const char *pinyin, size_t length);
size_t index_pinyin_copy_candidate(size_t index, uint16_t *output, size_t capacity);
size_t index_pinyin_choose(size_t index);
size_t index_pinyin_fixed_length(void);
void index_pinyin_flush(void);

#ifdef __cplusplus
}
#endif

#endif
