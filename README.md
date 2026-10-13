# Codex Usage Menubar · Codex 用量

轻量 macOS 菜单栏应用：显示 Codex **5 小时、每周剩余额度**与重置时间。非 OpenAI 官方项目。

## 功能

- 菜单栏剩余百分比、进度条和重置时间。
- 每分钟刷新、点击节流、失败退避、唤醒刷新和旧数据提示。
- 系统字体和大字设置；面板按内容与屏幕空间调整。
- 自动寻找 Codex CLI，也可手选路径；支持 Apple Silicon 和 Intel。

## 安装和使用

要求 macOS 13+、已登录的 Codex CLI（可使用桌面应用内置 CLI）及 Apple Command Line Tools。

下载源码并解压，在源码目录执行：

```sh
zsh 安装到本机.command
```

缺少编译工具时先运行 `xcode-select --install`。脚本本机编译并安装到 `~/Applications/Codex用量.app`，随后启动。使用现有 Codex 登录，不需要 GitHub 登录。

菜单栏左侧是 5 小时剩余，右侧是每周剩余。点击查看详情；齿轮设置字体、开机启动和 CLI 路径。Command 拖动菜单栏位置。

目前仅临时签名，未完成 Apple Developer ID 签名与公证。分享二进制时其他 Mac 可能提示不受信任，推荐本机源码编译。

## 原理与兼容性

启动本地 `codex app-server --listen stdio://`，读取 `account/rateLimits/read`，不发送模型推理请求。没有 Plus 限制，但仅实际验证过 Plus；其他套餐需返回兼容的额度窗口。API 余额、企业自定义额度不保证适用。

## 开发

```sh
zsh Scripts/test.sh
zsh build.sh
zsh Scripts/package.sh
```

默认构建 arm64/x86_64。单架构构建：`CODEX_USAGE_ARCHS=$(uname -m) zsh build.sh`。

`Sources/UsageCore.swift` 包含解析、RPC、路径发现及刷新控制；`Sources/main.swift` 包含原生界面；`Tests/` 使用人工数据和模拟进程。

正式签名公证见 `Scripts/release-notarized.sh`，需要自己的证书和钥匙串配置。

## 隐私、贡献与许可

无自建服务器、无内置遥测、不读取浏览器凭据或会话历史。CLI 自身认证和联网行为由 Codex 控制。详见 [隐私说明](PRIVACY.md)、[测试说明](TESTING.md)、[贡献指南](CONTRIBUTING.md)、[安全政策](SECURITY.md)。

MIT 许可证；参考项目见 [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)。
