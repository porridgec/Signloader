# Signloader

本地 iOS IPA 重签名工具（macOS SwiftUI）。把 IPA 拖进来 → 自动挑描述文件 → 签名 → 装到设备。

自己有证书（Apple Developer / 企业证书）但不想每次开 Xcode 或敲一长串 `zsign` 时用。签名和安装全部在本机完成，不经过任何服务器。

```bash
./build.sh            # release 构建 → build/Signloader.app
./build.sh install    # 装到 /Applications
```

依赖：`brew install zsign libimobiledevice`。启动时会检查缺失的工具并在标题栏提示。

## 签名工具包（signing kit）

Signloader 面向一个目录结构，默认 `~/.signloader/kit`（可在设置里改）：

```
<kit>/
├── cert.p12                    # 证书 + 私钥（任意 *.p12 都能识别）
├── *.mobileprovision           # 描述文件，放根目录
└── profiles-from-device/       # 或者放这个子目录
```

- **证书**：任意 `.p12`，密码在设置里填一次（存 Keychain），或用环境变量 `SIGNLOADER_P12_PASSWORD`。
- **描述文件**：自动按 `application-identifier` 去重，展示 bundle id、团队、到期时间、重复份数。
- 想刷新设备上的描述文件：`ideviceprovision copy <UDID> <kit>/profiles-from-device`，界面上也有一键导出。

## 用法

1. **拖 IPA 进来**（或 `⌘O`）。左栏解析出 App 名、版本、bundle id、图标、扩展、Watch App。
2. **自动匹配描述文件**，优先级：
   | 优先级 | profile | 含义 |
   |---|---|---|
   | 1 | `TEAM.bundleid.TEAM`（团队后缀） | 能覆盖安装、保留应用数据 |
   | 2 | `bundleid`（完全一致） | 可覆盖安装 |
   | 3 | `TEAM.*`（通配符） | 任意 bundle id 可签，但只能新装 |

   每行右侧的 ⓘ 可展开**详情**：App ID / UUID / 团队 / 有效期（带剩余寿命进度条）/ 平台 / 重复副本数，以及：
   - **证书** — profile 内嵌的每张证书（CN、团队、有效期），并标出哪张是当前 p12 里的那张；过期证书会单独标记。解析在进程内完成（手写 DER 解码），不为每张证书 spawn 一次 `openssl`。
   - **设备** — 全部已注册 UDID，可搜索、可复制；正在连接的设备会标「已连接」。
   - **Entitlements** — 完整键值列表。
3. **签名**（`S`）。默认直接 `zsign`；超过 500 MB 自动建议「大 App 安全模式」。
4. **安装**（`I`）。USB 连上设备即可，标题栏选设备。
5. 右侧日志实时输出 `zsign` / `ideviceinstaller` 的完整输出；签完给出校验：有没有 `_CodeSignature`、有没有内嵌 profile、内嵌的 `application-identifier` 是否与所选 profile 一致（这决定能不能覆盖安装）。

### 快捷键

`⌘O` 选 IPA · `⌘⇧O` 从主目录选 · `⌘R` 重扫工具包 · `⌘D` 刷新设备 · `S` 签名 · `I` 安装 · `⌘,` 设置

## CLI

同一个二进制带一套命令行，方便脚本化和排查：

```bash
Signloader profiles                     # 列出工具包里的 profile
Signloader profiles -v -m <子串>         # 展开单个 profile 的设备/证书/entitlements
Signloader devices                      # 列出已连接设备
Signloader info game.ipa [--json]       # 解析 IPA
Signloader sign game.ipa                # 签名（自动选 profile）
Signloader sign game.ipa --wildcard -o out.ipa
Signloader sign game.ipa --safe --install auto
Signloader verify signed.ipa -m <app-identifier>
```

`sign` 参数：`--safe`、`-o/--out`、`-i/--install <udid|auto>`、`--uninstall-first`、`-m/--profile <子串>`、`--wildcard`、`-z/--zip 0-9`、`-b/--bundle-id`、`--remove-extensions`、`--remove-watch`、`-k/--kit <路径>`、`--json`。

## 两条签名流水线

| | 命令 | 何时用 |
|---|---|---|
| 标准 | `zsign -k … -m … -o out.ipa app.ipa` | 默认，快 |
| 安全 | `unzip` → `zsign -f Payload/X.app` → `ditto` | 超大 IPA，zsign 自带打包可能异常 |

两条流水线的产物条目列表完全一致。

## 安全说明

- **密码只存 Keychain**（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`），不写 UserDefaults、不进仓库。命令行用 `SIGNLOADER_P12_PASSWORD` 覆盖。
- **启动只读不写**。早期版本每次启动都会把密码写回 Keychain，条目的 ACL 因此被重新钉在「当次构建的二进制」上——app 是 ad-hoc 签名，重签后 cdhash 变了，下一次启动就弹授权框。这是"每次构建都要授权"的根因。
- 修改密码时的 `SecItemUpdate` 是原地更新，不碰 ACL。
- Keychain 只在后台线程读：万一遇到需要授权的条目，弹框也不会卡在正在构建窗口的主线程上。
- **想彻底免弹框**（代价：本机任意进程可读，等价于 0600 文件），一次性执行：
  ```bash
  security delete-generic-password -a default -s app.signloader.p12-password 2>/dev/null
  security add-generic-password -a default -s app.signloader.p12-password -w '<密码>' -A
  ```
  程序内无法创建等价的「信任所有应用」条目（`SecAccessCreate` 传空列表实测不生效，且已弃用），所以只能用 `security -A`。
- **日志与错误信息里的密码会脱敏**成 `••••••`。
- 签名过程不发起任何网络请求。
- ⚠️ 已知限制：`zsign` 只接受命令行传密码，签名运行的几秒内本机 `ps` 能看到该参数。这是 zsign 的接口限制；介意的话在无其他用户的环境下使用。
- 工具本身只做「用自己的证书签自己的 IPA」，请遵守 Apple 开发者协议和当地法律。

## 实现上的几个坑

- **`zsign -R` 是在签完名之后删掉 `embedded.mobileprovision`**，不是"剥掉旧 profile 再签"。开着它签出来的包没有 profile，装不上。默认关闭。
- **`ditto` 打包必须加 `--norsrc --noextattr`**。macOS 给每个解出来的文件都打上 SIP 保护的 `com.apple.provenance`，`ditto` 默认会为它生成 `._name` AppleDouble 条目（`--sequesterRsrc` 则是生成一整棵 `__MACOSX/` 树）。`xattr -cr` 清不掉，只能靠这两个 flag。
- **判断能不能覆盖安装看 `application-identifier`**，不是 Info.plist 的 bundle id。
- **读 p12 可能需要 LibreSSL**：部分 `.p12` 用 RC2-40-CBC 加密，OpenSSL 3 默认 provider 读不了；优先尝试 `/usr/bin/openssl`，失败再退到 Homebrew 的。

## 图标

代码画的：`Tools/make-icon.swift` 用 CoreGraphics 渲染 10 个尺寸，`iconutil` 打包成 `.icns`。`Tools/check-icon.py` 在每次构建时自动断言几何（无裁切、字形居中、徽章在超椭圆内），改画法时直接告诉你有没有破坏版式。

## 结构

```
Sources/Signloader/
├── SignloaderApp.swift         # 场景 / 菜单 / 快捷键
├── AppModel.swift              # @Observable 状态与动作
├── Support/
│   ├── Shell.swift             # async Process 封装（流式输出、脱敏、不死锁）
│   ├── Keychain.swift          # 密码存储
│   ├── DER.swift               # 最小 X.509 解码（profile 内嵌证书）
│   └── CLI.swift               # 命令行前端
├── Models/                     # ProvisionProfile / IPAInfo / Device / SigningOptions
├── Services/
│   ├── SigningKitService.swift # 扫描工具包、解析 profile 与证书
│   ├── IPAParser.swift         # 不解包读 zip + 产物校验
│   ├── Signer.swift            # 两条签名流水线
│   └── DeviceService.swift     # idevice_* 封装
└── Views/                      # SwiftUI 界面
Tools/                          # 图标生成 + 几何自检
```

## License

MIT
