# llama-tuner — 按本机硬件自动调优 llama.cpp 启动参数

把 llama.cpp 的"专家驻留划分"调优思路做成全自动流程：**检测硬件 → 解析模型结构 → 计算最优显存划分 → 真实启动验证（失败自动降档）→ 生成启动脚本 + 桌面快捷方式**。

## 在一台新电脑上的用法

1. 把整个 `llama-tuner` 文件夹拷到新电脑任意位置（U盘即可，工具本身自包含）。
2. 确保模型 `.gguf` 在硬盘上（脚本会自动搜索 `D:\Models`、`C:\Users` 下最大的 gguf）。
3. 双击 `tune.cmd`。没有装 llama.cpp 也没关系——脚本会自动从 GitHub 下载官方 CUDA/Vulkan/CPU 发行版（可用 `-NoDownload` 关闭）。
4. 等待完成（首次含模型加载验证，约 5~15 分钟）。完成后：
   - 桌面出现 **启动LLM** / **停止LLM** 两个快捷方式
   - `tuning_report.txt` 是完整调优报告（硬件、模型结构、选定的 K 值、实测 t/s）
   - `config.json` 记住本次结果，重跑时秒级复用

## 调优逻辑（它替你做了什么）

| 检测项 | 决策 |
|---|---|
| 显存装得下整个模型 | `-ngl 99` 全量卸载，不做任何划分 |
| MoE 且装不下（如 8GB 卡 + 21GB 模型） | 计算最多能让前 K 层的专家权重常驻显存（这是预填充提速 3 倍的关键），其余层专家留 CPU；`-ot "blk.(K..N-1)\..*_exps.=CPU"` |
| 稠密模型装不下 | 折算成 `-ngl <层数>` 部分卸载 |
| 无 N 卡 | 纯 CPU 方案（AMD 用户自行换 Vulkan 版 llama.cpp） |
| **多显卡** | 显存预算合并计算、每卡单独预留计算缓冲、自动按容量比例生成 `--tensor-split`；专家驻留层数 K 按合并预算推导 |
| 模型 > 内存 80% | 上下文 16384 + KV 用 q8_0（省一半内存/显存） |
| 显存紧张 | 上下文 32768 + KV f16 |
| 固定通用项 | `-fa 1`、`-np 1`、`--cache-reuse 512`、`-b 8192 -ub 1024`，不开投机解码 |

估算出的 K 只是起点：脚本会**真实启动服务器验证**（二分搜索最大能起来的 K，失败自动降档），最终 K 还会留 1 层安全余量，实测的 pp/tg 写进报告。

### 多显卡说明

- 支持同构/异构多卡：显存预算合并、按各卡容量比例做 `--tensor-split`。
- 期望管理：非 NVLink 的卡间同步走 PCIe，多卡收益是**次线性**的（两张 8GB ≈ 1.5 张的收益，不是 2 张）；K 值划分的思路不变，只是"能常驻显存的专家层数"变多。
- 真正的兜底是**实测验证环**：任何激进的显存预算估算，只要真实启动失败就自动降档，所以多卡下的激进估算也是安全的。
- 已知边界：暂不使用 `-ot` 把指定层的专家钉到指定卡（`CUDA0/CUDA1`），如异构悬殊（如 8+24GB）建议手动微调。

## 常用参数

```
tune.cmd                              # 全自动
tune.cmd -SkipValidate                # 只出方案不实测（快）
tune.cmd -ModelPath E:\m.gguf        # 指定模型
tune.cmd -LlamaDir D:\Apps\llama     # 指定 llama.cpp 目录
tune.cmd -Port 8081                   # 换端口
tune.cmd -NoShortcut -NoDownload      # 不建快捷方式、不联网下载
tune.cmd -Force                       # 忽略缓存，重新实测验证
```

## 项目结构（改代码先看这里）

```
tune.ps1 / tune.cmd     入口，只做编排（按顺序调用 lib/）
lib/common.ps1          日志、停服务
lib/sysinfo.ps1         硬件检测（内存 / NVIDIA 显卡列表）
lib/gguf.ps1            GGUF 文件头解析 + 模型布局分析（纯读取）
lib/discover.ps1        找模型、找 llama.cpp、必要时自动下载
lib/plan.ps1            预算与参数计算（纯函数，无 I/O，最易测试）
lib/validate.ps1        真实启动二分验证（唯一会起进程的模块）
lib/launcher.ps1        生成 start/stop .cmd 与桌面快捷方式
tests/smoke.ps1         离线回归测试（不起服务、不联网，秒级跑完）
```

改 `lib/` 下任何文件前后都要跑：

```
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
```

它固化了本项目踩过的所有坑：GGUF 新旧两种 dims 宽度、层号正则的跨十位区间与选择组括号、
启动脚本的 `$$`/花括号/`timeout` 三个 cmd 生成 bug、CPU 方案不得出现 `-ngl 99`、
多卡预算与 tensor-split 数值、以及"函数名不得被内置别名遮蔽"的命名规约。

约定：所有函数带 `Tune/Gguf/Nvidia/Layer` 前缀（防别名遮蔽）；源码保持 ASCII；
中文文本走 `[regex]::Unescape`；纯计算逻辑放 `lib/plan.ps1`（便于离线测试）。

## 已知边界

- 验证过程会结束本机正在运行的 llama-server（换参数本来也要重启）。
- GGUF 结构通过解析文件头获得（不加载权重），对标准 llama.cpp 量化命名（`_exps.`）的 MoE 有效；极特殊架构会退回整层 `-ngl` 方案。
- 换了显卡/内存后重跑一次 `tune.cmd` 即可重新调优。
- 刚启动后的前几次请求偏慢是正常的：专家权重要从 NVMe 读进页缓存，越用越快。
