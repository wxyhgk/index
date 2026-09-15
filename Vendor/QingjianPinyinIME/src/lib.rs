//! 青简拼音引擎 FFI 桥：给 Swift 输入法壳用的 C ABI 接口。
//!
//! 全局单实例（Mutex 保护），macOS IMK 事件都在主线程，无并发。

use std::ffi::{c_char, CStr};
use std::path::Path;
use std::sync::Mutex;

use qingjian_core::Engine;
use qingjian_core::engine::Query;
use qingjian_dictionary::Dictionary;

struct FfiState {
    engine: Engine,
    last_query: Option<Query>,
}

static STATE: Mutex<Option<FfiState>> = Mutex::new(None);

/// 加载 .qj 词库并创建引擎。返回 true 成功。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_open(dict_path: *const c_char) -> bool {
    if dict_path.is_null() {
        return false;
    }
    let path = unsafe { CStr::from_ptr(dict_path) }
        .to_string_lossy()
        .to_string();
    let dict = match Dictionary::open_qj(Path::new(&path)) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("qingjian-ffi: failed to open dictionary: {e}");
            return false;
        }
    };
    let engine = Engine::new(dict);
    let mut guard = STATE.lock().unwrap();
    *guard = Some(FfiState {
        engine,
        last_query: None,
    });
    true
}

/// 输入一个字符（拼音键 a-z 或 '）。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_push(c: u16) {
    let mut guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_mut() {
        if let Some(ch) = char::from_u32(c as u32) {
            state.engine.push(ch);
        }
    }
}

/// 退格（删拼音缓冲区里的一个字符）。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_backspace() {
    let mut guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_mut() {
        state.engine.backspace();
    }
}

/// 应用侧退格（删的是已上屏的文字，学习信号）。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_note_backspace() {
    let mut guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_mut() {
        state.engine.note_backspace();
    }
}

/// 查询候选。返回候选数量。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_query() -> usize {
    let mut guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_mut() {
        match state.engine.query() {
            Ok(query) => {
                state.last_query = Some(query.clone());
                query.candidates.items.len()
            }
            Err(_) => 0,
        }
    } else {
        0
    }
}

/// 取第 index 个候选的文本。返回 UTF-16 字符数。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_copy_candidate(
    index: usize,
    output: *mut u16,
    capacity: usize,
) -> usize {
    let guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_ref() {
        if let Some(query) = &state.last_query {
            if let Some(candidate) = query.candidates.items.get(index) {
                return write_utf16(&candidate.text, output, capacity);
            }
        }
    }
    0
}

/// 提交第 index 个候选。返回上屏文本的 UTF-16 字符数。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_commit(
    index: usize,
    output: *mut u16,
    capacity: usize,
) -> usize {
    let mut guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_mut() {
        if let Some(query) = state.last_query.take() {
            if let Some(candidate) = query.candidates.items.get(index).cloned() {
                let text = state.engine.commit(&candidate);
                return write_utf16(&text, output, capacity);
            }
        }
    }
    0
}

/// 取当前 marked text（拼音显示形式）。返回 UTF-16 字符数。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_marked_text(output: *mut u16, capacity: usize) -> usize {
    let guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_ref() {
        if let Some(query) = &state.last_query {
            return write_utf16(&query.marked_text(), output, capacity);
        }
    }
    0
}

/// 清空拼音缓冲区。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_clear() {
    let mut guard = STATE.lock().unwrap();
    if let Some(state) = guard.as_mut() {
        state.engine.clear();
        state.last_query = None;
    }
}

/// 关闭引擎，释放资源。
#[no_mangle]
pub extern "C" fn qingjian_pinyin_close() {
    let mut guard = STATE.lock().unwrap();
    *guard = None;
}

fn write_utf16(text: &str, output: *mut u16, capacity: usize) -> usize {
    let utf16: Vec<u16> = text.encode_utf16().collect();
    let len = utf16.len().min(capacity);
    if !output.is_null() && len > 0 {
        unsafe { std::ptr::copy_nonoverlapping(utf16.as_ptr(), output, len) }
    }
    len
}
