# Intel / x86_64：WeChat 4.1.15.35（270115）适配记录

2026-11-15，本机 macOS 15.8.1、Intel x86_64、Swift 6.1.2 / Command Line Tools。
Intel 与 AMD 的目标指令集均为 x86_64；本次实际验证硬件是 Intel，不代表已验证 AMD 黑苹果环境。

## 当前可验证结果

- SwiftUI App 在 macOS 15 SDK 下编译、打包并打开设置向导。
- Go bridge 从固定 Go 1.25.14 / Frida 17.8.0 x86_64 devkit 构建，现有 Go 测试通过。
- `local` 模式可附加到本机已运行的微信；无需修改本次微信应用包。其它机器若拒绝附加，应先检查签名/权限，不能据此关闭 SIP。
- x64 Hook 校验实际加载库的 LC_UUID 和入口字节后安装；真实进程的状态查询返回 `ready=true`。
- x64 接收解码的私聊、长 UTF-8、群成员、群 @、自消息、去重及错误镜像拒绝测试通过。
- **真实消息接收与原生文本发送已验证**。手机发往文件传输助手的“Intel适配测试”经真实 Hook → Go bridge → 认证 OneBot WebSocket 两次匹配成功，打开会话时接收计数增至 31。`ready` 只表示 Hook 安装成功，接收需结合计数与事件。
- x64 原生任务向自己的文件传输助手发送 `Intel bridge 自检`，手机确认收到；补齐 completion 后，经 Go HTTP → Frida → 原生 service 发送 `Intel bridge 回调验证`，任务 286 完成，`lastErrorType=0` / `lastErrorCode=0`，微信进程稳定。首次 HTTP 测试发现旧 ARM `buf2resp` 等待导致误报超时，已让 x64 文本任务按原生提交结果返回。
- 当前 x64 配置标记 `enableSend=true`、`contactDirectory=true`；不复用 arm64 的 R3/媒体/朋友圈地址。通讯录复用 CommonCrypto 导出函数捕获与通用 SQLCipher 页解密逻辑，不依赖 `wechat.dylib` 静态 RVA，因此不需要 Hopper 重新定位微信原生入口。2026-11-15 本机验证实际 `contact.db` 解密成功，返回 2,736 个联系人、23 个群；密钥只在微信进程内存、bridge 内存和现有受限 key cache 流程中处理。
- x64 通讯录模块为 `hook/contact-directory-x64.js`，由 bridge 在主 x64 Hook 前拼接加载。App/bridge 更新并重启后，连接会立即安装 `CCCrypt` / `CCCryptorCreate` / `CCKeyDerivationPBKDF` 捕获 Hook；首次无缓存时须在 Hook 安装后打开通讯录/聊天，让微信触发 key 使用。未捕获密钥时返回 `key_missing`，不代表函数偏移错误。`x64_contact_directory_unverified` 是旧版 bridge Hook 的占位返回值。
- 入站图片下载入口已按当前 x64 镜像静态核对并加入 Hook：通过 `GetService("default")` 获取 CdnManager，构造 x64 `0x658` 字节下载参数后调用 `_startDownloadMedia`；bridge 同时等待 CDN 分片或微信写出的完整图片文件。此链路尚未用真实图片完成运行期验证，不能据此标记为真机媒体已验证。

## Hopper MCP 确认的镜像与地址

主程序 `Contents/MacOS/WeChat` 是启动壳。业务镜像为
`Contents/Resources/wechat.dylib`，应选择其 **x86_64 slice**。

| 项目 | 值 |
| --- | --- |
| `WeChatBundleVersion` | `4.1.15.35` |
| `CFBundleVersion` | `270115` |
| x86_64 LC_UUID | `4714EE3E-7227-3ED3-A10F-5E000414AA61` |
| universal 文件 SHA256 | `960222a9872c89a8ce14567427f2bb3e715435adbbd8723465ff7c253bb8fb30` |
| Hopper 静态镜像基址 | `0x0` |
| `__text` | `0x15000` 至 `0x79fc2ff`（末端不含） |
| `__TEXT` | `0x0` 至 `0xa3e1000`（末端不含） |
| `__DATA_CONST` | `0xa3e1000` 至 `0xa88e000`（末端不含） |
| 当前 PID 86830 的运行基址 | `0x123653000`；重启后必须重新获取 |

| 入口 / 数据 | RVA | 证据 / 限制 |
| --- | --- | --- |
| Message finalizer | `0x52f14c0` | `rdi=Message*`、`sil=mode`，检查 `Message+0x258`；已真实命中，测试消息经 OneBot 验证 |
| Message vtable | `0xa7544e8` | 构造函数 `0x52efdf0` 写入对象首指针 |
| MMReq2Buf wrapper | `0x605649c` | `MMReq2Buf` 字符串 xref；运行期有命中 |
| MMBuf2Resp wrapper | `0x605662c` | `MMBuf2Resp` 字符串 xref |
| ActionTask Req2Buf | `0x6059bf4` | `Req2Buf` / `actiontask_mgr.cc` 字符串 xref |
| ActionTask Buf2Resp | `0x6059f98` | `Buf2Resp` / `actiontask_mgr.cc` 字符串 xref |
| STN Req2Buf wrapper | `0x64f52ac` | `stn_callback_bridge.cc` 字符串 xref |
| MMStartTask | `0x604c980` | `rdi=mars::stn::Task*`，真实文本任务 opcode `0x20a`；不是高层文本发送 API |
| 文本任务 descriptor 构造器 | `0x33e8d90` | `rdi=descriptor*`，初始化 CGI URL、opcode 与默认 flags |
| 文本 Task 构造器 / 删除析构 | `0x33ea410` / `0x33ea500` | `rdi=Task*`、`rsi=descriptor*`，对象大小 `0xf0` |
| 文本 Req2Buf / Buf2Resp | `0x33ea530` / `0x33ea5d0` | 原生 protobuf 序列化和响应解析，已运行命中 |
| protobuf ParseFromArray | `0x61b0782` | `rdi=message*`、`rsi=bytes`、`edx=length`，返回 bool |
| protobuf SerializeString | `0x61b0c7c` | `rdi=输出 std::string*`、`rsi=message*` |
| service root 全局 / getter | `0xaceae00` / `0x4bec680` | 全局保存当前 service root 指针 |
| 文本 service getter | `0x4bed3b0` | root vtable `+0x18`；返回 service 子对象 |
| 文本 service vtable / 提交 thunk | `0xa733b30` / `0x4bb6620` | vtable `+0x28`，`rdi=service*`、`rsi=Task*` |
| 文本 Task vtable | `0xa68c4d8` | Req2Buf `+0x10`、Buf2Resp `+0x18`、request `+0x20` |
| GetService("default") | `0x601ebc8` | x64 下载路径服务定位器 |
| CdnManager 类型 getter | `0x61b2a4c` | getter 返回的 context `+0x40` 是 CdnManager |
| `_startDownloadMedia` | `0x62084ce` | `rdi=CdnManager*`、`rsi=0x658 字节下载参数`；返回 `0` 表示已受理 |
| `CreateC2CImageDownloadTask` | `0x639b866` | `_startDownloadMedia` 对 fileType 2 的分发目标 |
| `_OnRecvFileData` / `CdnFile::_WriteDecrypt` | `0x63451f8` / `0x621a5b0` | 下载接收与原生分片解密路径 |

计算：`运行地址 = 当前 wechat.dylib 加载基址 + RVA`。
当前 Message finalizer 地址为 `0x1289444c0`，不是固定基址。首次验证 PID 67935 的基址曾为 `0x127c06000`。
Hopper 文档 `wechat` 中已标注接收和文本发送关键函数，名称带 `verified` 的函数有运行期证据。

Message 布局：`type +0x0c`、`from +0x18`、`to +0x30`、`member +0x48`、
`serverId +0xf8`、`created +0x114`、`content +0x130`、`msgSource +0x160`。
x64 libc++ 字符串与 arm64 不同：短串长度为首字节右移一位、数据在 `+1`；
长串标志为首字节 bit 0、长度在 `+8`、数据指针在 `+16`。字符串长度是 UTF-8 字节数。
下载参数的四个字符串对象位于 `+0x40`、`+0x58`、`+0x70`、`+0x88`，类型在 `+0xa0`；
这些字段使用 x64 的 `capacity|1 / size / data` 布局，不能复制 arm64 模板中的指针顺序。

仓库原有的 `4_1_15_55_mac.json` 是 **270135 / arm64**。
其中 `0x597eda0` 在当前 x64 镜像中是另一个函数，不能只改版本字符串后继续使用。

## 本机复现

```bash
bash scripts/build_bridge.sh
bash scripts/fetch_gadget.sh
bash scripts/build_app.sh
open 'dist/WeChat AI.app'
python3 tools/inspect_wechat.py --pid "$(pgrep -x WeChat)"
node --test hook/tests/x86_64.test.cjs
python3 tools/validate_x64_text.py --pid "$(pgrep -x WeChat)"
```

需要复用调试构建时：

```bash
BUILD_CONFIGURATION=debug BUILD_SCRATCH="$PWD/app/.build" bash scripts/build_app.sh
```

命令行直接连接当前微信时，指定新版本配置和已存在的微信临时目录：

```bash
bash scripts/run_bridge.sh \
  --wechat-conf hook/versions/4_1_15_35_x86_64.json \
  --type local --image-path '/path/to/xwechat_files/account/temp'
```

`GET /voice_status` 使用相同 OneBot Bearer token，可查看 `hook.ready`、`hook.received`、
`hook.sendSupported`。确认接收必须看到 `received` 增长且对应 OneBot 消息事件到达；
只有 WebSocket 连接成功不算消息验证。发送提交不等于完成；`hook.submitted`、`hook.completed` 与 `hook.lastErrorType` / `hook.lastErrorCode` 可用于核验原生任务回调。

## x64 文本任务与生命周期

原生 Task：request 在 `+0x88`、response 在 `+0xb8`；completion 是 `+0x50` 的
`std::function<bool(Task*&, int&, int&)>`，其目标指针在 `+0x70`。
service 在 `0x4bb7974` 读取 completion，在 `0x4bb7995` 调用其 vtable `+0x30`。
空 completion 会在 `0x4bb79bc` 抛出 `std::bad_function_call`，即使消息已经送达也会使微信退出。

`bridge/native/text_completion.cpp` 用系统 libc++ 构造真实 completion；静态断言
`sizeof(std::function)==0x30`、alignment 为 16。回调记录完成与错误码并返回 true，
让微信 service 使用原生虚析构释放 Task。helper 作为 `bridge/libwechat-x64.dylib`
加载进微信，生命周期覆盖 Frida 断开后的待完成任务；不能用会随脚本卸载的 JS 回调替代。
Go bridge 启动时加载 helper；加载失败时不会启用发送。build_bridge / build_app 均包含 helper。

Go 生成 x64 正整数 31 位 clientmsgid。旧 34 位 ID 会被当前原生 uint32 字段截断；
Hook 在提交前执行完整 parse → serialize 字节校验，拒绝被截断或结构不兼容的 protobuf。
`tools/validate_x64_text.py` 不提交网络消息：它验证短文、长 UTF-8、completion 调用、
原生析构，并确认旧 34 位 ID 被拒绝，`submitted=0`。

原生 Task 通过 C++ `operator new` 分配，成功提交后归微信 service 所有；不回放已销毁的样本指针，
不复制捕获对象的 `shared_ptr` / `std::function` 内存。HTTP 成功表示任务已提交，
完成结果异步反映在 `/voice_status`。x64 文本任务不等待 ARM 旧 `buf2RespChan`。

## 系统能力边界

macOS 15 使用材质背景和标准按钮，较新 SDK 构建的 App 在 macOS 26 保留 Liquid Glass。
macOS 26 的 SpeechAnalyzer 需要较新 SDK / 系统；本机不提供此识别能力。
Qwen3-TTS 的 MLX 引擎依赖 Apple Silicon，Intel 不应下载该本地模型；文字链路不依赖它。
Command Line Tools 不包含 XCTest，本机 `swift test` 因 `no such module XCTest` 无法执行；
Swift App 编译成功和 Hook / Go 测试不能替代完整 Swift 测试。
最终 Go 全量测试与 Hook 测试通过。Intel 下旧 go-silk 16k 编码测试失败，已改用项目现有的官方 SILK SDK；语音发送 Hook 仍未启用。
