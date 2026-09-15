#ifndef QINGJIAN_PINYIN_BRIDGE_H
#define QINGJIAN_PINYIN_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 加载 .qj 词库并创建引擎。返回 true 成功。
bool qingjian_pinyin_open(const char *dict_path);

/// 输入一个字符（拼音键 a-z 或 '）。
void qingjian_pinyin_push(uint16_t c);

/// 退格（删拼音缓冲区里的一个字符）。
void qingjian_pinyin_backspace(void);

/// 应用侧退格（删的是已上屏的文字，学习信号）。
void qingjian_pinyin_note_backspace(void);

/// 查询候选。返回候选数量。
size_t qingjian_pinyin_query(void);

/// 取第 index 个候选的文本。返回 UTF-16 字符数。
size_t qingjian_pinyin_copy_candidate(size_t index, uint16_t *output, size_t capacity);

/// 提交第 index 个候选。返回上屏文本的 UTF-16 字符数。
size_t qingjian_pinyin_commit(size_t index, uint16_t *output, size_t capacity);

/// 取当前 marked text（拼音显示形式）。返回 UTF-16 字符数。
size_t qingjian_pinyin_marked_text(uint16_t *output, size_t capacity);

/// 清空拼音缓冲区。
void qingjian_pinyin_clear(void);

/// 关闭引擎，释放资源。
void qingjian_pinyin_close(void);

#ifdef __cplusplus
}
#endif

#endif /* QINGJIAN_PINYIN_BRIDGE_H */
