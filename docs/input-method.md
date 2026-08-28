# Index 输入即检索插件与可选输入源（实验）

正式推荐路径是主 App 的**输入即检索插件**：在“设置 → 插件”启用“输入即检索”，继续选择
微信输入法或苹果拼音，再打开 Index 状态栏菜单中的“输入即检索（兼容中文输入法）”。插件每
300ms 只读取当前光标前最多 128 个已经提交的字符，提取当前短语并查询本地数据库；结果显示
在光标附近。插件在当前进程支持即时启停：停用会立刻结束轮询、取消查询并关闭结果面板。

首次启用时 macOS 会请求辅助功能权限。这个模式不监听或吞掉按键，不替换当前输入法；
密码框、Index 自身窗口和无法安全读取文本范围的控件会被跳过。关闭菜单选项后会立即停止轮询。

`Index 搜索` 仅作为可选的实验性简体中文拼音输入源。它通过 InputMethodKit 管理 marked text，
使用 Apache-2.0 的 AOSP PinyinIME 在本机完成句级拼音解码、候选排序和用户词频学习；不依赖
Rime，也不下载网络词库。提交中文后，同一输入源会继续查询 Index 本地 SQLite。

组字期间，检索与输入转换是两条独立通道：Index 会同时查询原始拉丁字母和首选中文候选。
因此 `opencode` 可以直接命中英文内容，`jietu` 也可以通过首选候选“截图”命中中文内容；
空格仍提交中文候选，Return 提交原始英文，不用猜测用户最终准备输入哪一种语言。

## 当前边界

- 主 App 插件负责检索体验，不负责拼音组字、候选和用户词库；日常输入质量由用户选择的成熟输入法
  保证。插件关闭时，状态栏的兼容模式入口一并隐藏。
- 独立输入源是 macOS 单独启动的 bundle，不是主 App 进程内的 `Plugin` 实例，也不会因为设置页
  启用插件就自动安装。当前仍只保留手动安装与开发验证路径。
- 它不监听全局键盘，不需要输入监控权限；只有用户主动切换到 `Index 搜索` 输入源后才工作。
- 中文模式输入 `a-z` 进入拼音组字；空格提交当前候选，数字 `1–9` 选择候选，左右方向键移动选择，
  上下方向键或 Page Up/Page Down 翻候选页，退格删除拼音，Escape 取消，Return 提交原始拼音。
  候选条每页显示 9 项，也可以点击右侧箭头浏览后续候选。单独轻点 Shift 切换中英文并在光标旁
  显示“中”或“英”；`Shift + 字母`、系统快捷键和 Caps Lock 不触发切换。
- 拼音组字期间轻点 Shift，会把当前拼音按原始英文上屏并进入英文模式；英文模式的字母直接上屏，
  同时继续驱动 Index 原文检索。模式会在输入法进程重启后保留。
- AOSP 系统词库约 1 MB，用户学习数据仅写入
  `~/Library/Application Support/Index/InputMethod/pinyin-user.dat`。
- 当前只做本地 FTS/子串召回，不在每次按键时加载 CLIP 模型。语义图片结果应作为停顿后的
  第二阶段补充，不能阻塞首批结果。
- 直装版读取 `~/Library/Application Support/Index/index.sqlite`。Mac App Store 沙盒版若要与
  输入法稳定共享数据库或 IPC，需要先给两个签名目标配置同一个 App Group，并迁移数据根目录；
  当前实验 bundle 不进入商店上传包。
- 共存模式显式排除安全输入框；读取、短语提取、SQLite 检索都只在本机完成，不持久化所读取的
  输入上下文，也不发送到网络。

## 构建

遵守仓库唯一的 App 组装入口：

```bash
INDEX_BUILD_INPUT_METHOD=1 ./build.sh release
```

产物：

- `build/Index.app`
- `build/IndexSearchInputMethod.app`

显式启用后，`build.sh` 会在旁路目录完整组装和签名两个 bundle，再安全替换 `build/` 下的产物。
它不会把输入法复制进系统目录，也不会切换当前输入源。

## 手动安装测试

1. 在 Finder 中按 `⌘⇧G`，打开 `~/Library/Input Methods/`；目录不存在时先新建。
2. 把 `build/IndexSearchInputMethod.app` 复制进去，并保留这个文件名；不要复用旧输入法 bundle
   的安装路径，避免 HIToolbox 把不同 Bundle ID 的元数据合并。
3. 从安装路径运行一次注册命令：

   ```bash
   "$HOME/Library/Input Methods/IndexSearchInputMethod.app/Contents/MacOS/IndexInputMethod" --install
   ```

4. 注册命令会按照成熟输入法的安装流程，先调用 `TISRegisterInputSource`，
   再对顶层输入源调用 `TISEnableInputSource`。新版 macOS 仍会由系统设置询问
   用户是否启用，安装器不绕过这个确认。
5. 如果系统设置弹出确认，选择启用。如果没有弹窗，打开“系统设置 → 键盘 →
   文本输入 → 编辑 → +”，在**简体中文**分类中添加 `Index 搜索`。
6. 切换到 `Index 搜索`，输入 `nihao`，确认候选包含“你好”，按空格提交。
7. 提交至少 2 个中文字符后，本地内容查询会在停顿后显示。

如果在同一登录会话里反复安装过多次，或注册命令成功但系统设置仍不刷新，
退出当前账户再登录是 macOS 重建输入源会话的最终恢复步骤；不需要重启电脑。
重新登录前应先移除 `/Library/Input Methods/` 与 `~/Library/Input Methods/` 中的旧版、
重复或具有不同 Bundle ID 但同名的输入法 bundle，否则新会话仍可能扫描到冲突元数据。
测试新构建前先切换到别的输入法，不要在输入法进程仍运行时覆盖已经安装的 bundle。

## 实现结构

- `InputSearchPlugin`：主 App 内的正式插件边界，拥有兼容模式生命周期；通过
  `BuiltinPluginCatalog/BuiltinPluginHost` 与其他内置插件统一装配。
- `FocusedTextSearchController`：插件的平台适配器，辅助功能轮询、搜索取消和跟随光标面板都收在
  `Platform/`，不接管键盘事件。
- `IndexSearchCore`：无 AppKit 依赖；维护最长 64 字符的当前句尾、只读查询图库与剪贴板、
  合并排序并输出轻量 DTO。
- `AOSPPinyinIME`：直接封装 AOSP 的 C++ 解码核心和约 1 MB 系统词库；Apache-2.0 声明随包分发。
- `IndexInputMethod`：InputMethodKit marked-text 状态机、固定复用的拼音候选条、140ms 搜索防抖和
  迟到结果 generation 门。按键过程中不创建新窗口。
- `IndexApp`：仍拥有数据写入、迁移、CLIP 和完整图库交互；输入法不能反向修改数据库。

## 后续阶段

1. 给插件增加可选输入源的安装、更新、卸载和诊断状态；所有动作必须用户显式触发。
2. 用 App Group + XPC 让主 App 持有数据库和模型，输入源只传查询与接收 DTO。
3. 增加第二阶段 CLIP 语义结果，并对查询 generation 做同样的迟到丢弃。
4. 增加按 App 禁用、临时暂停、结果键盘导航与直接粘贴动作。

拼音解码器来自 [AOSP PinyinIME](https://android.googlesource.com/platform/packages/inputmethods/PinyinIME/)，
采用 Apache License 2.0；InputMethodKit 生命周期参考
[McBopomofo](https://github.com/openvanilla/McBopomofo)，未复制其输入引擎源码。
