# 发布

发布由 `.github/workflows/release.yml` 完成：同一份提交既推到 mooncakes.io，也打包
三端可执行文件挂到 GitHub Release。

## 发版步骤

1. 同步改两处版本号：
   - `moon.mod` 的 `version`
   - `src/core/version.mbt` 的 `VERSION`
2. 提交并推送到 `master`，等 CI 通过。
3. 在 GitHub 创建 Release，tag 用 `v<version>`（如 `v0.2.0`），指向 `master`，
   然后发布。工作流自动触发。

tag 只是标记：mooncakes.io 的版本号来自 `moon.mod`。工作流会先校验
`tag`（去掉 `v` 前缀）与 `moon.mod` 一致，再校验 `src/core/version.mbt` 与
`moon.mod` 一致，任何一处漂移都会在秒级失败。

也可以在 Actions 页手动 `Run workflow`：

- `tag` 留空：只发布到 mooncakes。
- `tag` 填已有 Release 的 tag：重新构建并上传该 Release 的二进制资产。

## 版本号限制

mooncakes.io 当前只接受主版本 `0`，版本号必须是 `0.x.y`。主版本非 0 时
`moon publish` 直接返回 403：

```text
Server status: 403 Forbidden, detail: In this very early stage, the major version must be '0'. The version should follow the format of `0.x.y`
```

所以 GitHub Release 的 tag 也只能是 `v0.x.y`；`verify` 的版本一致性校验与 registry
的限制共同决定可选版本。升级主版本前先确认 mooncakes 是否已放开该限制。

## 工作流结构

| Job | 内容 |
| --- | --- |
| `verify` | 版本校验 + 完整门禁：check、build、test、CLI golden、接口/格式检查、`moon install` 冒烟 |
| `publish` | 写入凭据后 `moon publish`；版本已在 mooncakes 上则跳过，便于重跑 |
| `build` | 三平台矩阵构建并打包 |
| `attach` | 汇总资产、生成 `SHA256SUMS`，用 `gh release upload` 挂到 Release |

`build` 与 `publish` 都只依赖 `verify`，互不阻塞：重新跑工作流生成二进制时，
不会因为版本已发布而失败。

## 产物

| 平台 | Runner | 文件 |
| --- | --- | --- |
| Linux x86_64 | `ubuntu-22.04` | `moonsearch-<version>-linux-x86_64.tar.gz` |
| macOS arm64 | `macos-15` | `moonsearch-<version>-macos-arm64.tar.gz` |
| Windows x86_64 | `windows-latest` | `moonsearch-<version>-windows-x86_64.zip` |

每个压缩包内是 `moonsearch`（Windows 为 `moonsearch.exe`）与 `LICENSE`。
`SHA256SUMS` 覆盖全部压缩包。

平台选择的原因：

- **Linux** 在 22.04 上构建，glibc 基线 2.35，当前 LTS 发行版都能运行。
- **macOS** 只出 arm64：MoonBit 的 `install/unix.sh` 不识别 `Darwin x86_64`，
  Intel Mac 没有可用的官方工具链。`macos-latest` 会把最低系统版本抬到 macOS 26，
  因此固定在 `macos-15`，最低要求 macOS 15。
- **Windows** 用 MSVC 构建；MoonBit 的链接配置包含静态 CRT（`libcmt.lib`），
  一般不需要额外安装 VC++ Redistributable。

## moon install

```bash
moon install q2316367743/moonsearch/cmd/moonsearch
```

这条路径不依赖 Release 资产：mooncakes 分发源码，`moon install` 在本机编译后把
`moonsearch` 装进 `~/.moon/bin`（Windows 为 `%USERPROFILE%\.moon\bin`）。需要
MoonBit 工具链与 C 编译器。

`moon.mod` 声明 `preferred_target = "native"` 与 `supported_targets = "native"`：
CLI 依赖文件系统与进程环境，Wasm 后端不可用，声明后 `moon install` / `moon build`
不会尝试其他后端。

`verify` 里的 `moon install ./cmd/moonsearch --bin "$RUNNER_TEMP/bin"` 是发布前的
冒烟测试：本地路径安装通过，注册表安装才有意义。

## 本地演练

```bash
moon check --target native --deny-warn
moon test --target native
moon testcli test tests/cli.md --target native
moon install ./cmd/moonsearch --bin /tmp/moonsearch-bin
/tmp/moonsearch-bin/moonsearch --version
```

手工验证压缩包内容：

```bash
moon build --target native --release
tar -czf /tmp/moonsearch-test.tar.gz \
  -C _build/native/release/build/cmd/moonsearch moonsearch.exe
```

## 一次性配置

仓库 Secrets 需要 `MOONCAKES_TOKEN`，值为 `~/.moon/credentials.json` 的完整内容
（一行 JSON，含 `token` 与 `username`）。工作流写入凭据后会先检查这两个字段，
发布结束（无论成败）删除凭据文件。

`attach` 使用 `GITHUB_TOKEN`，只需要该 job 的 `contents: write` 权限，无需额外
secret。
