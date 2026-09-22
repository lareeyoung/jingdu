# 镜读：同事测试包与源码构建

镜读支持 Apple Silicon（M1 及更新芯片）、macOS 14 或更新版本。当前包不包含 Intel 版本。

这是用于同事试用的 **ad-hoc 签名测试包**，没有 Developer ID 身份签名，也没有经过 Apple 公证。`codesign` 完整性核验通过并不表示 Apple 信任该开发者。不要把本机开发证书、签名私钥、钥匙串或密码分享给同事。

## 安装测试包

1. 从可信的分享位置取得 `Jingdu-版本-macOS-arm64.zip`、`RELEASE.json` 和 `SHA256SUMS`。只下载安装 ZIP 时，运行 `shasum -a 256 ZIP文件名`，与 `SHA256SUMS` 中该文件的值比较；如果下载了整套发行物，也可运行 `shasum -a 256 -c SHA256SUMS`，应全部显示 `OK`。这些校验值只能检查文件是否一致，不能代替对分享来源的确认。
2. 解压 ZIP，把其中的 `镜读.app` 拖入“应用程序”或自己的 `~/Applications` 文件夹，再打开。打包脚本不会替你安装或替换现有应用。
3. 下载来的未公证应用可能被 macOS 拦截。确认文件可信且校验一致后，可按 Apple 的说明，在尝试打开之后进入“系统设置 → 隐私与安全性”，查看是否提供“仍要打开”。公司管理的 Mac 可能不允许例外，此时由 IT 确认安装方式。本项目不要求关闭 Gatekeeper、不删除隔离标记、不修改全局信任。[Apple：安全地打开 Mac 上的 App](https://support.apple.com/zh-cn/102445)

如果需要面向更多用户、可验证开发者身份的正式发行，应由发布者另行使用自己的 Developer ID 签名并完成 Apple 公证；本脚本不持有该身份，也不执行这一步。[Apple：公证 macOS 软件](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 首次准备字幕模型

安装包已包含 whisper.cpp v1.8.3 的本地识别引擎和第三方许可证，没有 Homebrew 运行时依赖。**Whisper small 多语言模型没有打进安装包，也不进入 Git**，需准备一次，约 466 MiB（487,601,967 字节）。

普通使用者可以下载官方 [ggml-small.bin 多语言模型](https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin?download=true)，然后在镜读的“字幕 → 生成多语言字幕”中选择“选择已下载的语音模型”。应用会核对文件大小、模型头和完整文件哈希；不要使用 `small.en` 或仅改了名字的其他模型。

已有 Python 3 的使用者，也可以在解压后的文件夹运行：

```sh
python3 Scripts/prepare-subtitle-engine.py --model-only
```

此命令明确下载并验证模型，保存到 `~/Library/Application Support/Jingdu/SubtitleModels/ggml-small.bin`。默认只访问官方入口；官方入口不可达时，可自行决定是否添加 `--allow-mirror` 使用脚本列明的镜像，仍执行相同校验。应用在日常运行时不会自行下载模型。

模型上游 SHA-1：`55356645c2b361a969dfd0ef2c5a50d530afd8d5`。模型和 whisper.cpp 的许可证随应用附带。

人声识别在本机执行。非中文台词的中文翻译，以及视频脚本分析，使用你在“模型设置”中保存的服务地址、AppID、模型 ID 和 Key。请填写你自己的配置；发行文件不包含任何账号、Key 或作品。没有模型服务配置也可以使用本地播放、镜头标记、笔记等功能。

## 从干净源码构建同事测试包

需要 Apple Silicon Mac、Apple Command Line Tools（含 Swift 编译器）、Python 3.12 或更新版本。仅在重建字幕引擎时需要 CMake。请先准备这些开发工具；脚本不会自动安装软件或改变系统设置。

源码 ZIP 不含编译好的 `whisper-cli`，首次先执行：

```sh
python3 Scripts/prepare-subtitle-engine.py --engine-only
```

这一步从公开上游下载固定的 whisper.cpp v1.8.3 源码，验证 SHA-256 后编译 arm64 引擎；不会下载模型或调用模型服务。锁定的源码归档 SHA-256：`870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a`。

检查分发文件并生成发行物：

```sh
python3 Scripts/package-release.py --check
python3 Scripts/package-release.py --output-dir ./dist/本次版本
```

输出目录必须是一个新目录。生成内容：

- `Jingdu-版本-source.zip`：白名单源码、测试、构建脚本、通用文档、图标和第三方许可证；无编译引擎、模型权重、用户数据、签名材料或本机验证记录。
- `Jingdu-版本-macOS-arm64.zip`：本次重新编译的应用、本地字幕引擎、安装说明及可选模型准备脚本；仅临时候选包采用 ad-hoc 签名。
- `RELEASE.json`：版本、平台、签名/公证状态、源码文件与 ZIP 的 SHA-256。
- `SHA256SUMS`：两份 ZIP 和发行记录的 SHA-256。

只整理源码可使用 `--source-only`，不需要调用 Swift 或签名工具。工具遇到私钥材料、个人绝对路径、产品中的私有服务默认地址、符号链接、非系统动态库或异常附加文件会停止；请先清理来源，再重新打包。源码 ZIP 固定文件顺序、时间戳和权限；编译产物仍取决于本机 Swift/SDK 版本，不承诺跨工具链逐字节一致。

## 与本机开发版的区别

`build.command` 的默认行为保持不变：使用本机私有的固定签名身份构建开发版，以维持本机钥匙串访问身份。相关说明在 `Scripts/LOCAL-SIGNING.md`，这不是同事安装发行包的前置步骤。

`package-release.py` 只从白名单复制源码到临时目录，调用 `build.command --prepare` 编译独立候选，再对该候选签 ad-hoc。它不会调用本机固定签名脚本，不会读取 BuildSigning 文件，不会创建或导出签名私钥，不会修改钥匙串、信任设置、Git 配置或现有安装。也不会自动上传源码或创建 Git 仓库。

未公证测试包的不同版本不具备稳定的 Developer ID 发布身份；不要承诺在所有同事的系统或企业策略下免确认安装、免钥匙串授权升级。正式发行身份需另行配置与验证。
