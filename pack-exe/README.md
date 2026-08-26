# pack-exe — 把 DeepSeek Harness 打包成窗口应用

这是一个**独立于 DSH 源码**的打包工具目录。把它拷贝到任意版本的 deepseek-harness 仓库根目录下，运行打包脚本，即可产出一个自包含的 Windows 桌面应用 `out\dsh-app`：**双击 `dsh.exe` 直接弹出应用窗口使用 dsh，不需要浏览器，不需要安装 Node.js**。**不需要修改仓库的任何代码，全程 JavaScript（Electron）。**

## 目录结构

```
pack-exe/
├── build.ps1              主打包脚本（PowerShell）
├── app/                    Electron 主程序（纯 JS）
│   ├── main.js             主进程：启动 dsh 服务 + 创建应用窗口
│   ├── package.json
│   └── node_modules/       Electron 运行时（首次打包自动安装，可手动放置）
├── scripts/
│   └── copy-links.mjs     复制后重建 node_modules 的 junction 链接
└── out/dsh-app/            打包产物（运行时生成）
    ├── dsh.exe             Electron 应用主程序（双击即用）
    ├── *.dll / *.pak        Electron 运行时文件
    ├── VERSION.txt         版本信息
    └── resources/
        ├── app/            Electron 主程序代码（main.js）
        └── runtime/        独立运行时
            ├── node.exe    便携 Node.js
            └── repo/       仓库快照（含构建产物与完整 node_modules）
```

## 使用方式

### 首次打包

```powershell
# 在仓库根目录执行（自动完成：依赖安装 → 构建 → Electron 准备 → 打包）
.\pack-exe\build.ps1

# 产物：.\pack-exe\out\dsh-app\
```

### 使用打包好的应用

- **双击 `dsh.exe`** → 弹出 DeepSeek Harness 窗口（内嵌 Web UI），无浏览器依赖
- 关闭窗口即退出程序（dsh 服务进程随之结束）
- 整个 `dsh-app` 目录可拷贝到任何 Windows 10/11 机器直接运行
- 用户数据（会话、配置）存放在运行机器的 `%USERPROFILE%\.dsh`

### DSH 升级后重新打包

```powershell
# 方式 A：仓库原地升级（推荐，pack-exe 无需移动）
git pull
pnpm install && pnpm run build
.\pack-exe\build.ps1 -SkipBuild   # 产物已有，跳过构建可加速

# 方式 B：全新仓库
git clone https://github.com/deepseek-ai/deepseek-harness.git
# 把 pack-exe 目录整个拷贝到新仓库根目录，执行：
.\pack-exe\build.ps1
```

## 常用参数

| 参数 | 说明 |
|------|------|
| `-SkipBuild` | 跳过 `pnpm run build`（已有构建产物时加速） |
| `-SkipElectron` | 跳过 Electron 安装（已存在 `app\node_modules\electron` 时） |
| `-NodeDir <路径>` | 指定便携 Node 目录（默认自动探测常见位置） |

## 工作原理（简要）

1. **构建**：调用仓库自带的 `pnpm run build` 产出 TS 库与 Web 前端产物
2. **Electron 壳**：使用 Electron 42（`app\node_modules\electron\dist`，可手动放置或首次自动安装），主程序 `main.js` 负责：启动 dsh web 服务 → 轮询端口就绪 → 创建应用窗口加载 `http://127.0.0.1:3080` → 窗口关闭时结束服务进程树
3. **复制**：仓库快照（排除 `.git`/`node_modules`）+ 便携 `node.exe` + 完整 `node_modules` 到 `resources\runtime`
4. **重建链接**：pnpm 的 node_modules 依赖大量 junction 目录链接，robocopy 不保留，由 `copy-links.mjs` 遍历源树逐一重建并重映射目标路径
5. **验证**：设置环境变量 `DSH_GUI_SMOKE=1` 启动 `dsh.exe` 可在页面加载完成后自动退出（用于自动化冒烟测试）

## 开发调试

```powershell
# 使用已有产物里的 runtime 直接调试主程序（无需重新打包）
$env:DSH_GUI_RUNTIME = "D:\src\AI\deepseek-harness\pack-exe\out\dsh-app\resources\runtime"
cd pack-exe\app
..\app\node_modules\.bin\electron.cmd .
```

## 已知限制

- 产物体积较大（3GB+ 统计口径，其中约 1.4GB 为 node_modules 真实内容），这是 dsh 插件式架构与全量自包含的取舍
- `dsh plugin add`（运行时安装插件）依赖 pnpm 环境，在打包应用中不可用；如需扩展插件请在原仓库中安装后重新打包
- 打包环境要求：Windows 10/11、PowerShell 5.1+；首次打包需要网络下载 Electron（约 140MB，国内可手动下载 zip 放置到 `app\node_modules\electron\dist`）
