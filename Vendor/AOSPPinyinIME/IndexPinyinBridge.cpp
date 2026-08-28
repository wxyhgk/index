/* Index-specific wrapper around the Apache-2.0 AOSP PinyinIME decoder. */
#include "IndexPinyinBridge.h"

#include "internal/pinyinime.h"
#include "internal/utf16char.h"

bool index_pinyin_open(const char *system_dictionary, const char *user_dictionary) {
  return ime_pinyin::im_open_decoder(system_dictionary, user_dictionary);
}

void index_pinyin_close(void) {
  ime_pinyin::im_close_decoder();
}

void index_pinyin_reset(void) {
  ime_pinyin::im_reset_search();
}

size_t index_pinyin_search(const char *pinyin, size_t length) {
  return ime_pinyin::im_search(pinyin, length);
}

size_t index_pinyin_copy_candidate(size_t index, uint16_t *output, size_t capacity) {
  if (output == nullptr || capacity == 0) {
    return 0;
  }
  ime_pinyin::char16 *candidate = ime_pinyin::im_get_candidate(
      index,
      reinterpret_cast<ime_pinyin::char16 *>(output),
      capacity);
  if (candidate == nullptr) {
    output[0] = 0;
    return 0;
  }
  return ime_pinyin::utf16_strlen(candidate);
}

size_t index_pinyin_choose(size_t index) {
  return ime_pinyin::im_choose(index);
}

size_t index_pinyin_fixed_length(void) {
  return ime_pinyin::im_get_fixed_len();
}

void index_pinyin_flush(void) {
  ime_pinyin::im_flush_cache();
}
