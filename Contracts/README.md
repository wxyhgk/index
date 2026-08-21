# Index Portable Library Contract

这个目录定义 macOS 与未来 Windows 原生客户端之间的**数据边界**，不是要求两端
共享 Swift/C# 源码，也不是让两个进程共同打开运行中的 SQLite 数据库。

## v1 包结构

便携图库是一个后缀可由界面决定的普通目录：

```text
Example.indexlibrary/
├── manifest.json
├── originals/
│   └── <sha256>.png
└── assets/
    └── shot-<package-local-id>/
        └── asset-<package-local-id>-<asset-kind>/
            └── <original-file-name>
```

- `manifest.json`：UTF-8 JSON，格式见 `portable-library-v1.schema.json`。
- `originals/`：不可变 PNG，以小写 SHA-256 内容寻址；同内容只复制一次。
- `assets/`：录屏等文件附件。路径全部是 `/` 分隔的包内相对路径。
- 缩略图、FTS、CLIP/Vision 向量不导出：它们是可重新生成的平台缓存。
- XYZ 坐标以 `textContent` + `chemical/x-xyz` 明文写进 manifest，Windows 无需理解 Swift 的内部 JSON 编码。
- 尚未定义专用跨平台表达的内嵌附件，才保留为标准 base64 `payload`。

## 身份与同步边界

`shot-42`、`revision-8` 等引用只在**本次导出包内部**稳定，用来保持修订父子关系、
专题成员关系和附件归属。v1 是迁移/备份格式，不是双向同步协议；重复导入如何去重，
以 `contentHash` 和导入端策略决定。

不要通过 OneDrive、Dropbox 或网络盘让 macOS 和 Windows 同时打开同一个
`index.sqlite`/WAL。正确流程是：Index 导出独立包 → Windows 验证清单与哈希 →
导入 Windows 自己的本地数据库。

## 坐标

- 标注图层：始终为 `image-pixels-top-left`，单位是原图像素，见 `layers-v1.schema.json`。
- v1 macOS 捕获来源区域：`macos-global-points-bottom-left`，只作为出处元数据；
  Windows 不得拿它直接重放窗口位置。
- Windows 将来写入自己的捕获来源时必须使用新的显式 `coordinateSpace` 值。

## 兼容规则

- 读取端先检查 `format`、`formatVersion` 和 `minimumReaderVersion`。
- v1 字段集合由 Schema 冻结；新增字段或改变字段类型必须发布新的格式版本。
- 新增图层 `kind` 或改变既有字段语义时，必须提升图层契约版本并增加基准样本。
- 原图缺失会使导出整体失败，防止生成无法恢复的半包。
- 外置附件缺失不会丢掉资产身份：`missing=true`、`relativePath=null`，且不会泄露
  原机器绝对路径。

## 当前实现

- Swift DTO/编码：`Sources/Index/Storage/PortableLibrary.swift`
- 图层 Schema：`layers-v1.schema.json`
- 清单 Schema：`portable-library-v1.schema.json`
- 回归测试：`Tests/IndexTests/PortableLibraryTests.swift`
