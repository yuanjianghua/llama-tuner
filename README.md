# llama-tuner

**按本机硬件自动调优 llama.cpp 启动参数** ｜ **Auto-tune llama.cpp launch parameters for the hardware you actually have**

Zero-dependency PowerShell for Windows. No Python, no admin, no config files to hand-edit:
copy the folder to any Windows machine, double-click `tune.cmd`, get a launch script tuned by
**real launch + measured tokens/s** — not by a table of forum defaults.

零依赖 PowerShell 工具（Windows）。不用 Python、不用管理员权限、不用手改配置：
拷到任意 Windows 电脑，双击 `tune.cmd`，用**真实启动 + 实测 t/s** 验证出的启动脚本就生成好了——不靠论坛默认值抄表。

---

## English

### What it does

**Detect hardware → parse the GGUF header → compute the optimal VRAM split → validate with real
server launches (auto-demote on failure) → generate start/stop scripts + desktop shortcuts.**

1. Copy this folder anywhere (USB stick is fine — the tool is self-contained).
2. Keep your `.gguf` model on disk. It auto-picks the largest GGUF under `D:\Models` and `C:\Users`
   (or pass `-ModelPath`).
3. Double-click `tune.cmd`. llama.cpp not installed? It downloads the official CUDA/Vulkan/CPU
   release from GitHub automatically (`-NoDownload` disables that).
4. First run takes ~5–15 min (includes real load validation). You get:
   - desktop shortcuts **启动LLM / 停止LLM** (Start/Stop, Chinese labels), which also open `http://localhost:8080` when the server is healthy;
   - `tuning_report.txt` — full report: hardware, model structure, chosen K, measured pp/tg;
   - `config.json` — caches the result; re-runs finish in seconds.

### Day-to-day use (after tuning is done)

1. Double-click the **启动LLM** (Start) desktop shortcut — llama-server launches minimized
   (first model load takes ~1–2 min) and your browser opens the chat UI at `http://localhost:8080`
   once the server reports healthy. Nothing to type.
2. Chat in the browser, or treat it as an OpenAI-compatible API:
   `POST http://localhost:8080/v1/chat/completions` (model name is in `tuning_report.txt`).
3. Double-click **停止LLM** (Stop) when you are done.
4. Swapped the model or the hardware? Run `tune.cmd` again — cached re-runs take seconds,
   and anything that changed (GPU/RAM/model/context) triggers automatic revalidation.

### The tuning decisions it makes for you

| Detected situation | Decision |
|---|---|
| Whole model fits in VRAM | `-ngl 99`, full offload, no splitting |
| MoE bigger than VRAM (e.g. 8 GB card + 21 GB model) | Keep the experts of the first **K** layers resident on GPU (the key to ~3× prefill speedup), the rest stay on CPU: `-ot "blk.(K..N-1)\..*_exps\.=CPU"` |
| Dense model bigger than VRAM | Partial offload via `-ngl <layers>` |
| No NVIDIA GPU | CPU-only plan (AMD users: swap in a Vulkan build of llama.cpp) |
| **Multi-GPU** | VRAM budgets aggregated, per-card compute-buffer reserve, `--tensor-split` proportional to card size |
| Model > 70 % of RAM | KV cache quantized to `q8_0` (halves VRAM use) |
| **Context size** | Largest of 32768/16384/8192 whose KV fits 35 % of free VRAM budget (hybrid-SSM models have tiny KV — Qwen3.6-35B: 11 attention layers out of 41, 32K costs only 373 MB); if nothing boots, auto-demotes 32K→16K→8K and re-searches K |
| **Pagefile / commit budget** | Under WDDM every VRAM allocation also consumes the system *commit limit* (RAM + mounted pagefiles). Detects (a) a pagefile configured but **not mounted this boot** (a known Windows failure) and (b) total budget < model + 2 GB — both cause `cudaMalloc` **false OOM with VRAM free to spare**. Names the drive and offers one-shot repair via `tune.cmd -FixPagefile` |
| Always-on sane defaults | `-fa 1`, `-np 1`, `--cache-reuse 512`, `-b 8192 -ub 1024`, no speculative decoding |

The estimated K is only a starting point: the tuner **actually launches the server** (binary-searches
the largest K that boots, with realistic prompt measurement), keeps 1 layer of safety headroom, and
writes measured pp/tg into the report.

Multi-GPU: budgets aggregate and `--tensor-split` is proportional, but remember non-NVLink
card sync runs over PCIe — gains are sub-linear. The safety net is the real-launch loop: any
over-aggressive estimate demotes itself automatically.

### Flags

```
tune.cmd                              # fully automatic
tune.cmd -SkipValidate                # plan only, no test launches (fast)
tune.cmd -ModelPath E:\m.gguf         # explicit model
tune.cmd -LlamaDir D:\Apps\llama      # explicit llama.cpp folder
tune.cmd -Port 8081                   # custom port
tune.cmd -NoShortcut -NoDownload      # no desktop shortcuts, no network
tune.cmd -Force                       # ignore cache, revalidate with real launches
tune.cmd -FixPagefile                 # re-register unmounted pagefiles (admin, then reboot)
```

### Architecture enforced by tests

Low coupling is machine-enforced, not a badge: `lib/modules.json` is the single source of truth for
load order and allowed cross-module dependencies; `tests/arch.ps1` rebuilds the real call graph
from the sources and fails on undeclared calls, zombie deps, cycles, alias-shadowed function names,
functions in the entry script, I/O inside the `pure` planning module, or any file over 250 lines.
`tests/smoke.ps1` adds behavior regressions harvested from field incidents (GGUF dim widths,
layer-range regex edge cases, cmd-generation bugs, WDDM false-OOM detection…).
Run `tests\all.cmd` before and after touching `lib/`.

### Known limits

- Validation stops a running llama-server (changing parameters needs a restart anyway).
- GGUF knowledge comes from parsing the file header; expert splitting relies on standard
  `_exps.` tensor naming — exotic archs fall back to plain `-ngl` offload.
- Changing GPU/RAM **or context size** invalidates the cached K and triggers revalidation.
- **Out of memory although VRAM looks free?** Almost certainly the commit budget — re-run
  `tune.cmd` and look for `COMMIT BUDGET LOW` / `PAGEFILE NOT MOUNTED`.
- The first few requests after launch are slower: expert weights stream from NVMe into the OS page
  cache; it gets faster as you use it.

---

## 中文说明

把 llama.cpp 的"专家驻留划分"调优思路做成全自动流程：**检测硬件 → 解析模型结构 → 计算最优显存划分 → 真实启动验证（失败自动降档）→ 生成启动脚本 + 桌面快捷方式**。

### 在一台新电脑上的用法

1. 把整个 `llama-tuner` 文件夹拷到新电脑任意位置（U盘即可，工具本身自包含）。
2. 确保模型 `.gguf` 在硬盘上（脚本会自动搜索 `D:\Models`、`C:\Users` 下最大的 gguf）。
3. 双击 `tune.cmd`。没有装 llama.cpp 也没关系——脚本会自动从 GitHub 下载官方 CUDA/Vulkan/CPU 发行版（可用 `-NoDownload` 关闭）。
4. 等待完成（首次含模型加载验证，约 5~15 分钟）。完成后：
   - 桌面出现 **启动LLM** / **停止LLM** 两个快捷方式（服务器健康后自动打开 `http://localhost:8080`）
   - `tuning_report.txt` 是完整调优报告（硬件、模型结构、选定的 K 值、实测 t/s）
   - `config.json` 记住本次结果，重跑时秒级复用

#### 日常使用（调优完成之后）

1. 双击桌面 **启动LLM**：llama-server 在后台启动（首次加载模型约 1~2 分钟），就绪后自动打开浏览器聊天页（`http://localhost:8080`），全程不用敲命令。
2. 浏览器里直接对话；也可以当 OpenAI 兼容 API 用：`POST http://localhost:8080/v1/chat/completions`（model 名写在 `tuning_report.txt` 里）。
3. 用完双击桌面 **停止LLM**。
4. 以后换了模型或硬件，再双击一次 `tune.cmd` 即可——有缓存时几秒完成，变了的东西（显卡/内存/模型/上下文）会自动重新实测。

## 调优逻辑（它替你做了什么）

| 检测项 | 决策 |
|---|---|
| 显存装得下整个模型 | `-ngl 99` 全量卸载，不做任何划分 |
| MoE 且装不下（如 8GB 卡 + 21GB 模型） | 计算最多能让前 K 层的专家权重常驻显存（这是预填充提速 3 倍的关键），其余层专家留 CPU；`-ot "blk.(K..N-1)\..*_exps\.=CPU"` |
| 稠密模型装不下 | 折算成 `-ngl <层数>` 部分卸载 |
| 无 N 卡 | 纯 CPU 方案（AMD 用户自行换 Vulkan 版 llama.cpp） |
| **多显卡** | 显存预算合并计算、每卡单独预留计算缓冲、自动按容量比例生成 `--tensor-split`；专家驻留层数 K 按合并预算推导 |
| 模型 > 内存 70% | KV 缓存自动量化 `q8_0`（省一半显存） |
| **上下文大小** | 按 **KV 实测预算**取 32768 / 16384 / 8192 中最大档（KV 上限=空闲显存预算的 35%；混合 SSM 模型 KV 极小——如 Qwen3.6-35B 41 层仅 11 层注意力，32K 也只要 373MB）；若真实启动全失败还会 32K→16K→8K 自动降档并重搜 K |
| **页面文件 / 提交预算** | WDDM 下每次显存分配都同时占用系统"提交限额"（= 内存 + 已挂载页面文件）。检测两类故障：**配置了但本次开机没挂载**（Windows 已知毛病）、**总预算 < 模型大小 + 2GB**，两者都会让 cudaMalloc 在显存空余时假 OOM；报出问题盘符并给出 `tune.cmd -FixPagefile` 一键修复 |
| 固定通用项 | `-fa 1`、`-np 1`、`--cache-reuse 512`、`-b 8192 -ub 1024`，不开投机解码 |

估算出的 K 只是起点：脚本会**真实启动服务器验证**（二分搜索最大能起来的 K，失败自动降档），最终 K 还会留 1 层安全余量，实测的 pp/tg 写进报告。

#### 多显卡说明

- 支持同构/异构多卡：显存预算合并、按各卡容量比例做 `--tensor-split`。
- 期望管理：非 NVLink 的卡间同步走 PCIe，多卡收益是**次线性**的（两张 8GB ≈ 1.5 张的收益，不是 2 张）；K 值划分的思路不变，只是"能常驻显存的专家层数"变多。
- 真正的兜底是**实测验证环**：任何激进的显存预算估算，只要真实启动失败就自动降档，所以多卡下的激进估算也是安全的。
- 已知边界：暂不使用 `-ot` 把指定层的专家钉到指定卡（`CUDA0/CUDA1`），如异构悬殊（如 8+24GB）建议手动微调。

### 常用参数

```
tune.cmd                              # 全自动
tune.cmd -SkipValidate                # 只出方案不实测（快）
tune.cmd -ModelPath E:\m.gguf        # 指定模型
tune.cmd -LlamaDir D:\Apps\llama     # 指定 llama.cpp 目录
tune.cmd -Port 8081                   # 换端口
tune.cmd -NoShortcut -NoDownload      # 不建快捷方式、不联网下载
tune.cmd -Force                       # 忽略缓存，重新实测验证
tune.cmd -FixPagefile                 # 重新注册"配置了但没挂载"的页面文件（需管理员，完成后重启）
```

### 项目结构（改代码先看这里）

```
tune.ps1 / tune.cmd     入口，只做编排，不定义任何逻辑函数（arch 测试强制）
lib/modules.json        模块清单：加载顺序 + 允许的跨模块依赖（唯一事实源）
lib/load.ps1            按清单加载模块，顺序错误当场报错
lib/common.ps1          日志、停服务
lib/sysinfo.ps1         硬件检测（内存 / NVIDIA 显卡 / 提交预算与页面文件挂载状态 + -FixPagefile 修复）
lib/gguf.ps1            GGUF 解析 + 布局分析（零依赖：不写日志、不认识别的模块）
lib/plan.ps1            预算与参数计算（标记 pure：禁止一切副作用，最易测试）
lib/state.ps1           config.json 读写与缓存有效性判断
lib/discover.ps1        找模型、找 llama.cpp、必要时自动下载
lib/validate.ps1        真实启动二分验证（唯一会起进程的模块；参数行由入口注入）
lib/launcher.ps1        生成 start/stop .cmd 与桌面快捷方式
tests/arch.ps1          架构耦合审计：扫描源码发现真实调用图，与 modules.json 逐一比对
tests/smoke.ps1         行为回归（含二分搜索、GGUF 双格式、cmd 生成三连坑、假 OOM 检测）
tests/all.cmd           一次跑完两套测试
```

低耦合不是口头约定，是**机器强制**的：

- 任何模块偷偷调用别的模块的函数而没写进 `modules.json` → `tests/arch.ps1` 直接红，并点名是哪次调用；
- 清单里声明了但代码里已不存在的依赖（僵尸依赖）同样报错；
- `plan.ps1` 标记 `pure`，出现任何 I/O、进程、网络原语即报错；
- 还检查：依赖图无环、清单顺序合法、函数不重名、不被内置别名遮蔽、每个文件 ≤250 行（防再长成 530 行巨石）、入口脚本不得定义函数。

改 `lib/` 下任何文件前后都要跑：

```
tests\all.cmd
```

（它跑过检测器自己也得自证有效——用"故意注入一句隐藏依赖"的演习确认过审计会红。）

它固化了本项目踩过的所有坑：GGUF 新旧两种 dims 宽度、层号正则的跨十位区间与选择组括号、
启动脚本的 `$$`/花括号/`timeout` 三个 cmd 生成 bug、CPU 方案不得出现 `-ngl 99`、
多卡预算与 tensor-split 数值、WDDM 提交预算假 OOM 的检测、以及"函数名不得被内置别名遮蔽"的命名规约。

约定：所有函数带 `Tune/Gguf/Nvidia/Layer` 前缀（防别名遮蔽）；源码保持 ASCII；
中文文本走 `[regex]::Unescape`；新增模块必须同时登记进 `lib/modules.json`（漏登记 arch 测试会拦）；
跨模块要协作就把依赖写进清单，或者用注入（参考 `Find-BestTuneK` 的 argBuilder）。

### 已知边界

- 验证过程会结束本机正在运行的 llama-server（换参数本来也要重启）。
- GGUF 结构通过解析文件头获得（不加载权重），对标准 llama.cpp 量化命名（`_exps.`）的 MoE 有效；极特殊架构会退回整层 `-ngl` 方案。
- 换了显卡/内存后重跑一次 `tune.cmd` 即可重新调优；换**上下文大小**（含规则升级）同样会让缓存的 K 失效并重新实测。
- **显存空余却报 OOM**？十有八九是提交预算：跑一次 `tune.cmd` 看有没有 `COMMIT BUDGET LOW` / `PAGEFILE NOT MOUNTED` 警告（2026-11-22 实机事故：D 盘 32GB 页面文件重启后未挂载，限额 47→17GB，加载模型假 OOM）。
- 刚启动后的前几次请求偏慢是正常的：专家权重要从 NVMe 读进页缓存，越用越快。
