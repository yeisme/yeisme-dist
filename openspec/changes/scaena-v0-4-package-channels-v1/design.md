## Context

`yeisme-dist` 当前把 `scaena/v0.2.1` 作为单一 product 镜像，匿名 installer 只解析 product name，现有 Scaena Cask 方向也只考虑 Linux CLI。Scaena `v0.4.0` 上游合同改为同一 tag 下三个角色、每个角色六个平台，共 18 个 archives；catalog canonical identity 仍必须是 `scaena`。

本仓是公共 mirror，不读取、不构建、不 vendor 私有产品源码。`catalog.json` 和 `receipts/**` 是脚本/CI 产物，Cask/Scoop manifests 也必须由 generator 生成。当前工作树已有其他产品的 package-manifest 改动，本 change 只能增量扩展 Scaena 路径，不得回退或覆盖这些并行修改。

## Goals / Non-Goals

**Goals:**

- 原样镜像并验证 Scaena 三角色 18 archives 与 required metadata。
- 保持 catalog schema 1 和单一 `scaena` product，使用有界静态 alias 支持三个 public package name。
- 在 mirror 和 asset digests 完成后原子生成三个 Casks 与三个 Scoop manifests。
- 保持现有 `install.sh scaena` 默认 CLI 行为，并 additive 支持 API/worker。
- RC 只产生临时 package evidence；stable manifests 只指向已验证公共资产。

**Non-Goals:**

- 不重建 Scaena binary，不访问其源码 checkout。
- 不新增 catalog `packages[]`、第二套 release history 或三个 product entries。
- 不发布 `.deb`、`.rpm`、`.apk`、Docker image 或 package repository。
- 不注册 systemd、launchd、Windows Service 或 `brew services`。
- 不在本 change 推广通用多包 schema；出现第二个明确多包产品后再单独设计。

## Decisions

### 1. 静态 package descriptor 而不是 catalog schema 变更

在 installer 与 manifest generator 共用一个 Scaena descriptor：

| Requested package | Catalog product | Archive prefix | Installed binary |
| --- | --- | --- | --- |
| `scaena` | `scaena` | `scaena_` | `scaena` |
| `scaena-api` | `scaena` | `scaena-api_` | `scaena-api` |
| `scaena-production-worker` | `scaena` | `scaena-production-worker_` | `scaena-production-worker` |

默认 package 不指定时仍解析 `scaena`。选择静态 descriptor 是因为当前只有一个多包产品，能避免把一次产品特例升级成全局 catalog migration。descriptor 必须由 installer/generator 的同一测试 fixture 校验，防止两个脚本漂移。

### 2. Scaena verify policy 固定完整 Release eligibility

Scaena 从 `v0.4.0` 起 opt in `yeisme.dist_verify_policy.v1`。Eligible stable Release 必须满足：

- tag 符合 `scaena/vX.Y.Z` 且不是 prerelease；
- 三个 prefix × `linux|darwin|windows` × `amd64|arm64` 的 18 archives 完整；
- Unix archive 为 `.tar.gz`，Windows 为 `.zip`；
- `checksums.txt` 覆盖所有 required assets；
- 每个 archive 有匹配的 SPDX SBOM；
- command catalog、`BINARY-DISTRIBUTION-NOTICE.txt` 和 Scaena handoff metadata 完整；
- mirrored asset digests 与 upstream exact bytes 相同。

Scaena owner 提供的 release fixture 是资产名真源。Policy 由仓库脚本从冻结 fixture 生成并校验，不手写 `policy/scaena.json`。

### 3. Mirror 完成后才生成 manifests

状态机：

```text
verified upstream facts
  -> exact-byte public mirror
  -> immutable success receipt
  -> catalog asset_digests complete
  -> render all 3 Casks + all 3 Scoop manifests
  -> syntax/style/static validation
  -> public install/version/help/uninstall smoke
  -> generated files eligible for commit
```

Generator 先写临时目录，验证六份输出都成功后再原子替换工作树 generated files。任一角色/平台/digest 缺失时不改任何 Scaena manifest，保留上一稳定版本。

### 4. Homebrew 与 Scoop 只安装对应 binary

三个 Homebrew Cask 支持 macOS 与 Linux 的 amd64/arm64 archive selector；三个 Scoop manifest 支持 Windows amd64/arm64。Manifests 只安装对应 binary，不声明 package dependencies、service stanza 或后台启动动作。

公共命令合同为：

```bash
brew tap yeisme/dist https://github.com/yeisme/yeisme-dist
brew install --cask yeisme/dist/<package>
```

```powershell
scoop bucket add yeisme https://github.com/yeisme/yeisme-dist
scoop install yeisme/<package>
```

这些命令在远端 manifests 与公共 smoke 完成前只属于 planned contract，不得写成当前 active。

### 5. 匿名 installer 保持默认兼容

`install.sh scaena [version]` 继续选择 CLI archive 并安装 `scaena`。`install.sh scaena-api [version]` 和 `install.sh scaena-production-worker [version]` 先把 requested package 解析为 catalog product `scaena`，再按自身 prefix 选择当前 OS/arch archive。

选择逻辑必须使用完整 prefix 边界，禁止 `scaena_` 误匹配 `scaena-api_`。Installer 继续验证 checksums，且不安装 archive 中的 service/config 辅助文件到系统目录。

### 6. RC 与 stable 隔离

Upstream prerelease 可以被 dry-run/fixture 路径消费，但不会推进 catalog `latest`、success receipt 或 stable manifests。RC 的 Cask/Scoop 只渲染到临时目录或临时 Tap/Bucket，并在 job 结束后销毁。

Stable 失败时不回写已存在 receipt，不改上一稳定 manifest。若有缺陷版本已触达公共渠道，通过下一 patch 修复，不复用 tag 或改写 mirrored bytes。

### 7. 证据与权限

PR CI 不需要 credential，使用 synthetic catalog、archives、digests 和 temporary install roots 覆盖三 aliases。受控 sync 才使用 `DIST_SYNC_TOKEN` 读取 upstream 与写本仓 Release；token 不进入脚本参数、日志、receipt 或 fixture。

公共 smoke 至少覆盖：

- Homebrew：macOS/Linux × amd64/arm64 的 URL、SHA、install、`--version`、`--help`、uninstall；
- Scoop：Windows amd64/arm64 的 URL、hash、install、`--version`、`--help`、uninstall；
- anonymous installer：三个 package 在可用 OS/arch 上选择正确 archive/binary；
- negative：缺失 worker ARM、错误 digest、prerelease、prefix collision 均不推进 manifests。

## Risks / Trade-offs

- `[Risk]` 静态 descriptor 形成产品特例。→ 限定为一个共享表和 fixture；第二个多包产品出现时再评估 schema。
- `[Risk]` 六份 manifest 部分生成造成版本分裂。→ 临时目录生成并原子替换，全组失败即保持旧版本。
- `[Risk]` upstream 发布早于公共 mirror。→ manifest eligibility 依赖本仓 receipt 与 `asset_digests`，不依赖 dispatch 声明。
- `[Risk]` ARM hosted runner 暂不可用。→ 渠道保持上一 stable，不用交叉编译结果替代 native smoke。
- `[Risk]` 当前工作树已有并行 package 改动。→ 实现时只租用 Scaena-specific descriptor/policy/fixtures 与必要共享分支，先基于最新 main 合并，不覆盖其他产品。

## Migration Plan

1. 从 Scaena owner 接收并冻结 v0.4 release fixture、notice digest 与 expected asset set。
2. 增加 policy generator、静态 package descriptor 和 fail-closed offline tests。
3. 扩展 anonymous installer 与 manifest generator，在 synthetic catalog 上验证三个 package。
4. 用 `v0.4.0-rc.1` exact assets 做临时 Tap/Bucket smoke，不改 stable generated files。
5. stable upstream Release 镜像和 receipt 成功后生成六份 manifests，完成公共 smoke，再更新 README/channel matrix。

回滚时恢复上一稳定 generated manifests；保留 immutable success/failure evidence，不改写既有 receipt 或 mirrored Release。已公开上游 tag 通过下一 patch 修复。

## Open Questions

无。package 名、catalog identity、资产矩阵、渠道、RC 策略、服务边界与失败策略均已由 root handoff 冻结。
