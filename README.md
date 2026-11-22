# llama-tuner

**按本机硬件自动调优 llama.cpp 启动参数** ｜ **Auto-tune llama.cpp launch parameters for the hardware you actually have**

Zero-dependency PowerShell for Windows. No Python, no admin, no config files to hand-edit:
copy the folder to any Windows machine, double-click `tune.cmd`, get a launch script tuned by
**real launch + measured tokens/s** — not by a table of forum defaults.

零依赖 PowerShell 工具（Windows）。不用 Python、不用管理员权限、不用手改配置：
拷到任意 Windows 电脑，双击 `tune.cmd`，用**真实启动 + 实测 t/s** 验证出的启动脚本就生成好了——不靠论坛默认值抄表。

---

## English

### Prerequisites (check these 60 seconds first)

| Need | Detail |
|---|---|
| Windows 10/11 x64 | PowerShell 5.1 is built in — nothing else to install. No admin rights needed (except `-FixPagefile`). |
| NVIDIA driver installed | Open Task Manager → Performance: does it show your GPU by name? If not (or it says "Microsoft Basic Display"), install drivers via Windows Update → Optional updates, or https://www.nvidia.com/en-us/drivers/ — the tuner will also detect and tell you. AMD GPUs: plan manually (Vulkan build). |
| Disk space | Model file + ~8 GB free on the same drive (scratch/pagefile headroom). The tuner warns if it's tight. |
| A GGUF model | No model yet? Download one: [Hugging Face GGUF models](https://huggingface.co/models?library=gguf) · China mirror: [ModelScope](https://modelscope.cn). A Q4_K_XL / Q4_K_M quantization of a 20–35B MoE model is the sweet spot for an 8 GB card + 16 GB RAM. |
| llama.cpp | Optional — auto-downloaded. GitHub too slow from your network? See Troubleshooting below. |
| Internet (first run only) | For the llama.cpp download and GitHub release check. |

### What this tool does NOT do

- It does not download models (links above) and does not install GPU drivers (it detects and tells you).
- It does not run as a service; start/stop are your two desktop shortcuts.
- It never touches anything outside its own folder except: two desktop shortcuts, and (only with `-FixPagefile`, admin) the pagefile registration.

### What it does

**Detect hardware → parse the GGUF header → compute the optimal VRAM split → validate with real
server launches (auto-demote on failure) → generate start/stop scripts + desktop shortcuts.**

1. **Unzip first** (if you downloaded a ZIP, extract the whole folder — double-clicking inside the ZIP archive only unpacks one file and breaks the `lib\` paths). Copy the folder anywhere (USB stick is fine — the tool is self-contained).
2. Keep your `.gguf` model on disk. It auto-picks the largest GGUF under `D:\Models`, `D:\Dev` and `C:\Users`
   (or pass `-ModelPath`). No model yet? See Prerequisites for where to get one.
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
over-aggressive estimate demotes itself automatically. **Status: the multi-GPU path has unit tests
but has never been run on a physical dual-GPU machine** (the reference machine below has one card).

### Troubleshooting on a clean machine

- *No GGUF model found* — the auto-search only covers `D:\Models`, `D:\Dev`, `C:\Users`; put your
  model there or pass `-ModelPath C:\path\model.gguf`.
- *GitHub download slow/blocked* — manually download `llama-*-bin-win-cuda-cu12.*-x64.zip` **and**
  `cudart-llama-bin-win-cuda-12.*-x64.zip` from the
  [llama.cpp releases page](https://github.com/ggml-org/llama.cpp/releases), unpack both into one
  folder, then `tune.cmd -LlamaDir <that folder>`.
- *Popup: `VCRUNTIME140.dll` / `MSVCP140.dll` missing* — install the VC++ 2015-2022 x64 runtime:
  <https://aka.ms/vs/17/release/vc_redist.x64.exe>.
- *Port 8080 busy* — `tune.cmd -Port 8081`.

### FAQ

- *First requests are slow, then get faster?* Normal — expert weights stream from NVMe into the OS
  page cache; minutes of use and it warms up.
- *Chat response suddenly stops mid-sentence in a very long conversation?* The context window is
  full — start a new chat (numbers: 32K context here).
- *Conversation got cut when I re-ran tune.cmd?* Expected: re-validation must restart the server.
- *API smoke test:*
  `curl http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"Qwen3.6-35B-A3B-UD-Q4_K_XL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"`
- *Uninstall:* delete the folder and the two desktop shortcuts. Nothing else was touched (unless you
  ran `-FixPagefile`, whose pagefile entry you manage via System settings).

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
tune.cmd -CpuOnly                     # have an NVIDIA GPU but want CPU-only anyway
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

- **Field-verified on one reference machine only** (16 GB RAM + RTX 5060 Laptop 8 GB — specs in the
  measured section above). Multi-GPU and other hardware plans come from the same budget math and are
  always backed by the real-launch validation loop, but have not been field-run elsewhere yet.
  **Explicitly: the multi-GPU code path (aggregated budget + `--tensor-split`) is only covered by
  unit tests and has NEVER been run on a physical dual-GPU machine — every speed number in this
  README comes from the single 8 GB card above.**
  If you try it on another machine, sharing your `tuning_report.txt` would be very welcome.
- Validation stops a running llama-server (changing parameters needs a restart anyway).
- GGUF knowledge comes from parsing the file header; expert splitting relies on standard
  `_exps.` tensor naming — exotic archs fall back to plain `-ngl` offload.
- Changing GPU/RAM **or context size** invalidates the cached K and triggers revalidation.
- **Out of memory although VRAM looks free?** Almost certainly the commit budget — re-run
  `tune.cmd` and look for `COMMIT BUDGET LOW` / `PAGEFILE NOT MOUNTED`.
- **SSD wear, honestly**: when the model is bigger than RAM (reference machine: 21.3 GB model vs
  16 GB RAM), expert weights are streamed from NVMe through the OS page cache — up to ~21 GB of
  *reads* each time the cache goes cold (reboot, or big apps evicting standby memory). SSD endurance
  (TBW) is rated by *written* bytes; NAND wear from reads is negligible. The write side stays small
  too (pagefile churn from an overcommitted working set — typically a few GB per session, orders of
  magnitude below the hundreds of TBW a mainstream NVMe is rated for). To minimize even that:
  add RAM (also the single best speed upgrade) and close other memory-heavy apps while running.
- The first few requests after launch are slower: expert weights stream from NVMe into the OS page
  cache; it gets faster as you use it.

---

## Measured on this machine · 实测机型与速度

Reference machine (the only machine field-verified so far) · 参考实机（目前唯一完整验证过的机器）:

| 项 · Item | 值 · Value |
|---|---|
| 机型 · Machine | Lenovo Legion·拯救者 (83F3) |
| CPU | Intel Core Ultra 7 255HX · 20 核/20 线程 · cores/threads |
| 内存 · RAM | 16 GB (15.4 GiB usable) |
| 显卡 · GPU | NVIDIA GeForce RTX 5060 Laptop · 8 GB (driver 616.56) · **x1 单卡 · single GPU** |
| 硬盘 · Disk | UMIS 1 TB NVMe SSD |
| 系统 · OS | Windows 11 Home 中文 · build 26200 |
| 模型 · Model | Qwen3.6-35B-A3B · Unsloth Dynamic **Q4_K_XL** · 21.3 GB · MoE, 41 layers, hybrid-SSM (11 attention layers) |
| 调优结果 · Tuned | ctx 16K + KV q8_0 + 专家驻留 K=5（提交预算受限时实测值；预算充足时实测 K=6） |

速度 · Speed（本机实测 · measured on this machine）:

| 指标 · Metric | 数值 · Value | 主要限制 · Main limit |
|---|---|---|
| 解码 tg | **≈ 25 tok/s** | 内存带宽 + CPU 侧专家层 · RAM bandwidth + CPU-side experts |
| 预填充 pp · warm | **≈ 70–80 tok/s** | NVMe 页缓存热后转内存带宽 · RAM bandwidth once page cache is warm |
| 预填充 pp · cold | **≈ 10–12 tok/s** | NVMe 读盘 · NVMe page-in（前几分钟 · first minutes） |
| KV 32K 上下文 | 仅 373 MB · tiny | 混合 SSM 架构，KV 不构成瓶颈 · hybrid-SSM, KV is not the limit |

速度口径 · Measurement conditions（真实使用累计，非跑分脚本 · real usage counters from `/metrics`, not a benchmark script）:

- 服务端配置 · Server: `-c 16384` · KV `q8_0` · `-b 8192 -ub 1024` · `--cache-reuse 512` · `-np 1`（单对话槽 · one slot）
- **tg ≈ 25 t/s**：全天真实长对话累计 **28,269 解码 token / 1,074 s = 26.3 t/s**；回答含思维链，单次输出常见数百~一两千 token，上下文用到过上限 16,383。Cumulative decode over a full day of real long chats.
- **pp 热 ≈ 70–80 t/s**：单条长 prompt 热缓存值；全天平均 **63 t/s**（25,239 个未命中缓存的 prompt token，包含刚开机的慢启动段）。Full-day uncached average incl. cold-start phase.
- **pp 冷 ≈ 10–12 t/s**：刚重启、模型未进页缓存时，调优验证环用 ~320-token prompt 实测。Measured by the tuner's validation loop right after reboot.
- 前缀缓存另计 · Prefix cache: 累计 **45,261** 个 prompt token 直接复用、几乎免费（长对话越多越省）。Not counted in pp.
- 该架构 KV 极小，以上数字在 ctx 32K 下基本不变 · Numbers hold at 32K ctx too (KV is tiny on this arch).

如实说明 · Honest notes：

- **这台机器的瓶颈是 16 GB 内存 < 21.3 GB 模型**：专家权重靠 NVMe→内存页缓存分层，冷缓存时预填充在等读盘（10 t/s 级），热了以后受内存带宽与 CPU 算专家层限制；解码 25 t/s 同理。KV 反而是最不成问题的。 The 16 GB RAM < 21.3 GB model mismatch is the bottleneck; KV is not.
- **目前只在这一台机器上完整实测过**（single-machine field test only）。多显卡等方案由同一套预算推导 + 实启动验证兜底，尚未在别的机型上跑过。
- **SSD 寿命**：该配置对 NVMe 以**读**为主（缓存变冷时整模型最多重读 ~21 GB）。TBW 按写入计，读损耗可忽略；写侧（页面文件换出）每会话几 GB 量级，距主流 NVMe 数百 TBW 质保差几个数量级。正解是加内存——同时还是最大的提速项。 Read-dominated streaming; TBW is write-based, NAND wear from reads is negligible; more RAM fixes both speed and worry.

---

## 中文说明

把 llama.cpp 的"专家驻留划分"调优思路做成全自动流程：**检测硬件 → 解析模型结构 → 计算最优显存划分 → 真实启动验证（失败自动降档）→ 生成启动脚本 + 桌面快捷方式**。

### 开始之前（1 分钟自查）

| 需要什么 | 说明 |
|---|---|
| Windows 10/11（64 位） | 自带 PowerShell，不用装任何别的东西；全程不需要管理员权限（只有 `-FixPagefile` 需要） |
| 已装 NVIDIA 显卡驱动 | 任务管理器 → 性能，能看到显卡型号即已装。看不到/显示"Microsoft 基本显示适配器"→ 先装驱动（Windows 更新→可选更新，或 https://www.nvidia.com/en-us/drivers/ ）；工具也会自动检出并提醒。A 卡用户需自行换 Vulkan 版 llama.cpp 手动调 |
| 磁盘空间 | 模型文件所在盘：模型大小 + 至少 8GB 余量（页面文件/临时空间），空间不足工具会警告 |
| 一个 GGUF 模型 | 还没有模型？去 [Hugging Face](https://huggingface.co/models?library=gguf) 或国内 [ModelScope 魔搭](https://modelscope.cn) 下载 GGUF 量化文件；8GB 显存 + 16GB 内存的机器建议选 20~35B MoE 模型的 Q4_K_XL / Q4_K_M 量化 |
| llama.cpp | 可以不装，工具自动下载；GitHub 太慢见下方「故障排查」 |
| 网络 | 仅首次运行需要（下载 llama.cpp / 查版本） |

**这个工具不会做的事**：不替你下载模型（上面有下载入口）、不替你装显卡驱动（会检测并提醒你）、不作为系统服务常驻（起停用桌面两个快捷方式）。除了自己文件夹内的文件和桌面两个快捷方式，它不碰系统任何东西（只有 `-FixPagefile` 例外，且需要你明确执行并同意 UAC）。

### 在一台新电脑上的用法

1. **先解压**：下载的是 ZIP 就必须先**完整解压**再双击——在压缩包里直接双击只会解出那一个文件，`lib\` 目录不在旁边必然报错。解压后整个文件夹放哪都行（U盘也行，工具自包含）。
2. 确保模型 `.gguf` 在硬盘上（自动搜索 `D:\Models`、`D:\Dev`、`C:\Users` 下最大的 gguf；没有模型见上方下载入口，或 `-ModelPath` 指定）。
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
- 实测状态：**多卡路径只有单元测试，从未在真实双卡机器上验证过**（上文参考机为单卡）。

### 故障排查（全新电脑常见问题）

- *提示找不到 GGUF 模型*——自动搜索只覆盖 `D:\Models`、`D:\Dev`、`C:\Users`；把模型放这些位置，或用 `-ModelPath C:\路径\model.gguf`。
- *GitHub 下载慢/连不上*——去 [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases) 手动下载 `llama-*-bin-win-cuda-cu12.*-x64.zip` **和** `cudart-llama-bin-win-cuda-12.*-x64.zip`，解压到同一个文件夹，再跑 `tune.cmd -LlamaDir <该文件夹>`。
- *弹窗缺 `VCRUNTIME140.dll` / `MSVCP140.dll`*——安装 VC++ 2015-2022 运行库(x64)：<https://aka.ms/vs/17/release/vc_redist.x64.exe>。
- *8080 端口被占*——`tune.cmd -Port 8081`。

### 常见问题

- *刚启动前几次对话明显慢？* 正常：专家权重要从 NVMe 读进系统页缓存，用几分钟就快了。
- *超长聊天回答说到一半突然停？* 上下文用满了——开个新会话（本机上下文 32K，普通聊天很难碰到；写长文/塞大文件容易碰到）。
- *重跑了 tune.cmd，正在进行的对话被掐断？* 预期行为：重新实测必须重启服务器。
- *API 冒烟测试：*
  `curl http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"Qwen3.6-35B-A3B-UD-Q4_K_XL\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}"`
- *怎么卸载：* 删掉本文件夹 + 桌面两个快捷方式即可，系统里没有别的东西（若用过 `-FixPagefile`，页面文件设置请到 系统属性→高级→性能→高级→虚拟内存 里自行调整）。

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
tune.cmd -CpuOnly                     # 明明有 N 卡但就是想先用 CPU 跑
tune.cmd -CpuOnly                     # 明明有 N 卡但就是想先用 CPU 跑
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

- **目前只在一台参考实机上完整验证过**（16GB 内存 + RTX 5060 Laptop 8GB，配置见上文实测机型）。多显卡及其它硬件方案由同一套预算逻辑推导，并有“真实启动实测”兜底，但尚未在别的机器上实跑过——欢迎你在自己机器上跑完后把 `tuning_report.txt` 反馈给我。**明确说明：多显卡代码路径（合并预算 + `--tensor-split`）目前只有单元测试覆盖，从未在真实双卡机器上跑过；本页所有速度数字都来自上面那张单张 8GB 卡。**
- 验证过程会结束本机正在运行的 llama-server（换参数本来也要重启）。
- GGUF 结构通过解析文件头获得（不加载权重），对标准 llama.cpp 量化命名（`_exps.`）的 MoE 有效；极特殊架构会退回整层 `-ngl` 方案。
- 换了显卡/内存后重跑一次 `tune.cmd` 即可重新调优；换**上下文大小**（含规则升级）同样会让缓存的 K 失效并重新实测。
- **显存空余却报 OOM**？十有八九是提交预算：跑一次 `tune.cmd` 看有没有 `COMMIT BUDGET LOW` / `PAGEFILE NOT MOUNTED` 警告（2026-11-22 实机事故：D 盘 32GB 页面文件重启后未挂载，限额 47→17GB，加载模型假 OOM）。
- **关于固态硬盘寿命（如实说）**：模型大于内存时（参考机 21.3GB 模型 vs 16GB 内存），专家权重要经系统页缓存从 NVMe 反复调入——缓存每变冷一次（重启、或被大内存应用挤掉），最多重读约 21GB，**这是读不是写**。SSD 寿命指标 TBW 按写入量计，读对颗粒的损耗几乎可忽略；写侧也有限（主要是内存超配带来的页面文件换出，通常一次会话几个 GB 量级），与主流 NVMe 数百 TBW 的质保相差几个数量级，正常使用不必焦虑。想再省：加内存（同时也是最大的提速项）、跑模型时关闭其它大内存应用。
- 刚启动后的前几次请求偏慢是正常的：专家权重要从 NVMe 读进页缓存，越用越快。
