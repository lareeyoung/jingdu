# 镜读的本机固定签名

此方案让同一台 Mac 上更新的镜读继续使用同一个代码身份，避免每次重新构建后的 ad-hoc 签名改变身份。它用于本机开发，不代表 Apple 开发者认证、公证或可分发的 Developer ID 签名。

`sign-local-app.py` 只为 `CFBundleIdentifier = local.jingdu.studio`、可执行文件为 `Jingdu` 的应用签名。它不会读取或改写镜读的模型 Key，也不会修改已有凭据的访问控制。

## 准备和首次启用

首次启用前，先生成独立候选包，现有安装不会被替换：

```sh
JINGDU_APP_OUTPUT='/tmp/jingdu-candidate/镜读.app' ./build.command --prepare
```

`--prepare` 必须明确指定安装目录以外的输出位置，不调用签名工具或建立信任。普通构建则只使用固定签名，完成校验后才替换输出应用；失败保留旧应用。

在仓库目录执行准备阶段：

```sh
python3 Scripts/sign-local-app.py prepare
```

准备阶段不会建立任何证书信任。它在当前用户的 `~/Library/Application Support/Jingdu/BuildSigning` 创建固定的十年本机证书和专用 `signing.keychain-db`，不修改默认钥匙串或搜索列表。重复执行会检查并复用现有身份；材料缺失、权限异常或证书不匹配时停止，不自动重新生成身份。

首次建立信任属于独立、明确的操作。确认其下述范围后，才执行：

```sh
python3 Scripts/sign-local-app.py trust-and-sign '/tmp/jingdu-candidate/镜读.app'
```

该阶段会先核对应用身份，随后仅对准备阶段生成的固定证书执行以下信任设置；macOS 可能要求一次用户认证：

```sh
JINGDU_SIGNING_DIR="$HOME/Library/Application Support/Jingdu/BuildSigning"
security add-trusted-cert -r trustRoot -p codeSign \
  -a /usr/bin/codesign \
  -k "$JINGDU_SIGNING_DIR/signing.keychain-db" \
  "$JINGDU_SIGNING_DIR/certificate.der"
```

范围是 **当前用户域 + codeSign 用途 + `/usr/bin/codesign` 应用**。没有 `-d`，不写管理员域或系统域；没有 SSL、邮件或其他用途。`trustRoot` 表示这张自签证书在上述限定条件下作为信任终点，不是无条件信任所有用途的根证书。

信任约束和私钥权限是两件事：专用钥匙串的签名私钥只允许 Apple 的 `/usr/bin/codesign` 签名，不授予任意应用访问；私钥仅允许签名且不可导出。目录权限为 `700`，状态文件、证书和钥匙串文件为 `600`。用于自动解锁这个专用钥匙串的随机密码只保存在该私有状态文件中，不写入命令行参数、仓库或输出。初始化时的私钥 PEM 和加密 PKCS12 临时文件会在导入后清理；每次操作结束时锁定专用钥匙串。签名期间临时把专用钥匙串加入用户搜索列表，使系统工具能够找到身份；结束时仅撤回本次新增的路径，保留其他并发改动，不修改默认钥匙串，也不改变任何项目的访问控制。

上述文件权限保护不同用户之间的访问，不能防御已经控制当前登录账户的程序。不要把整个签名目录复制进仓库、共享目录或应用资源。

## 后续构建

构建脚本仅调用普通签名模式：

```sh
python3 Scripts/sign-local-app.py sign "$HOME/Applications/镜读.app"
```

`sign` 不建立、修复或重新授予证书信任。每次显式指定专用钥匙串和固定证书指纹，写入如下 designated requirement，并检查完整签名、固定身份和实际嵌入的证书：

```text
identifier "local.jingdu.studio" and certificate leaf = H"<固定证书 SHA-1>"
```

这里 SHA-1 是 Apple requirement 语言规定的证书定位方式；证书签名使用 SHA-256。任何签名或验证失败都会停止，绝不回退到 ad-hoc 或只有 identifier 的宽松身份。构建集成必须保留这个失败状态，不能把失败产物作为更新安装。

旧的 ad-hoc 镜读曾保存的模型凭据，可能需要在首次使用固定签名版本时重新授权一次。已用两份不同二进制、同一固定身份进行隔离验证：更新版本在关闭交互的条件下可以读取原版创建的测试凭据；临时签名的同名程序被拒绝。旧版真实 Key 的一次迁移授权仍需由用户在 macOS 弹窗中完成。

首次签名候选包验证通过后，再在退出镜读的情况下替换安装。后续直接运行 `./build.command` 复用这次身份，信任设置不会在构建时自动修改。

## 撤销信任或停止使用

下面是手动撤销命令，仅移除这张镜读证书的用户域信任记录；不会删除证书、签名私钥、模型 Key、素材或项目：

```sh
JINGDU_SIGNING_DIR="$HOME/Library/Application Support/Jingdu/BuildSigning"
security remove-trusted-cert "$JINGDU_SIGNING_DIR/certificate.der"
```

撤销后普通 `sign` 不会重新授予信任；应停止使用这套构建流程。若明确决定恢复，重新执行 `trust-and-sign`。`identity.json` 的启用标记只是本机流程记录，不能绕过系统实际信任验证。

如只想停止这套构建方式，移除构建脚本对本辅助脚本的调用，并保留签名目录；不要自动生成新的证书覆盖它。恢复旧版应用请使用已保存的原应用备份，旧版身份的凭据授权由 macOS 处理。本脚本没有删除签名目录、删除登录钥匙串条目或修改原凭据 ACL 的功能。

## 隔离检查与目前的验证边界

准备阶段可以单独指定测试目录，不使用真实签名目录：

```sh
python3 Scripts/sign-local-app.py --state-dir /tmp/jingdu-signing-review/BuildSigning prepare
python3 Tests/LocalSigningTests.py
```

已在专用临时目录验证准备阶段成功、重复准备保留身份、文件权限、密码不出现在输出，以及默认钥匙串和搜索列表保持不变。专用私钥的签名 ACL 只有 `/usr/bin/codesign`；无需读取其私钥内容即可检查。23 项离线测试模拟 `codesign` 和信任操作。2026-09-21 经用户明确授权后，已实际建立上述限定信任，完成固定签名、完整验证和安装；普通构建复用同一身份成功，签名搜索列表恢复。两份不同构建的测试凭据读取及拒绝无相同身份程序的验证均已通过，见 `验证记录-1.4.4.md`。

Apple 官方依据：[TN3161：签名证书与身份查找](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)、[Code Signing Requirement Language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)。身份查找要求签名机信任证书链；固定 DR 的验证不会因为省略 `trusted` 而自动改变任何系统信任设置。
