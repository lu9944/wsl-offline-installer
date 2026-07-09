# WSL2 离线安装管理工具

通过 GitHub Actions 构建一个完整的 WSL2 离线安装包，内含 WSL2 内核和 Ubuntu 发行版镜像。在无网络的 Windows 机器上只需运行一个脚本即可完成安装、卸载和环境检测。

## 构建发布包

工作流定义在 `.github/workflows/build-offline-package.yml`。

- 推送到 `main` 分支自动构建并发布。
- 或在 **Actions** 页面手动运行 **Build offline WSL2 package**。

工作流会下载 WSL 安装包和 Linux rootfs 镜像，打包成 zip，上传为 GitHub Release 资产。

默认 Release tag 为 `wsl2-offline-latest`，每次运行都会更新该 tag 并替换资产。可通过工作流输入自定义发行版名称、rootfs URL、架构和 tag。

## 使用方法

在有网的机器上下载 release zip，拷贝到离线 Windows 机器上解压。

以管理员身份打开 PowerShell，运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\WSL2-Offline.ps1
```

将看到交互菜单：

```
=============================================
             WSL2 离线安装管理工具
=============================================

  [1] 安装 WSL2  (启用功能 -> 安装内核 -> 导入发行版)
  [2] 卸载 WSL2  (注销发行版 -> 移除组件 -> 禁用功能)
  [3] 检测环境   (查看当前 WSL 状态和安装包情况)

  [0] 退出

请选择操作:
```

### 安装

选择 `[1]` 后脚本会自动执行：

1. 检测 CPU 虚拟化是否开启
2. 启用 Windows 功能 (WSL + 虚拟机平台)
3. 如果需要重启 → 提示重启，**重启后再次运行同一脚本**，自动跳过已启用的功能继续安装
4. 安装 WSL2 内核 (MSI)
5. 交互式选择发行版安装位置（可指定到 D 盘等非 C 盘路径）
6. 导入 Ubuntu 发行版镜像

> **关于重启：** 首次运行如果 Windows 功能需要重启，脚本会提示。重启后再次运行脚本，它会自动检测到功能已启用，直接继续安装内核和发行版，无需手动分步操作。

也支持命令行直接指定参数跳过交互：

```powershell
.\WSL2-Offline.ps1 -Action Install -InstallRoot D:\WSL
```

### 卸载

选择 `[2]` 后，脚本会确认（输入 y），然后执行四级清理：

1. 正常注销所有发行版
2. 重启 LxssManager 服务后重试
3. 强制清理注册表 + Appx 包 + 数据目录
4. 移除 WSL 框架、卸载 MSI、禁用 Windows 功能

```powershell
.\WSL2-Offline.ps1 -Action Uninstall -Force
```

### 检测环境

选择 `[3]` 会显示：操作系统、CPU 虚拟化状态、Windows 功能状态、WSL 版本、已安装发行版、离线包是否就绪、磁盘空间，并给出综合结论。

## 包结构

```text
WSL2-Offline.ps1
packages/
  wsl.*.msi
images/
  *.rootfs.tar.gz
manifest.json
SHA256SUMS
```

## License

MIT License. See [LICENSE](LICENSE).
