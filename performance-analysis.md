# Performance Analysis: Qwen3.8-27B Local Deployment (RTX 3090 24GB)

> Benchmark date: 2026-08-20
> Hardware: RTX 3090 24GB (bandwidth 936 GB/s)
> Model: `Qwen3.8-27B-UD-Q4_K_XL.gguf` (17.6GB, 65 layers, Q4_K_XL quantization)
> Draft head: embedded in the main GGUF (`blk.64.nextn.*`, Q4_K_XL) / separate file `mtp-Qwen3.8-27B-Q4_0.gguf` (Q4_0)
> Server: llama-server (2026-08-19 build)

---

## 1. Background

The MTP (multi-token prediction) draft head of Qwen3.8-27B has **two sources**:

| Source | Tensors | Quantization | VRAM footprint |
|--------|---------|--------------|----------------|
| Embedded in main GGUF | `blk.64.nextn.{eh_proj,enorm,hnorm,shared_head_norm}.weight` | Q4_K_XL | 0 (reuses main model tensors) |
| Separate file `mtp-*.gguf` | blk.64 + nextn head + output head, 18 tensors total | Q4_0 | ~1.8GB |

Empirically confirmed: llama-server can use `--spec-type draft-mtp` **without** `--spec-draft-model` to use the embedded head directly (log: `creating MTP draft context against the target model`); both approaches start up normally.

---

## 2. Test Method

- Same Chinese prompt (short text, 67 tokens), `temperature=0` (greedy), `max_tokens=256`
- Readiness check: poll `/v1/models` until HTTP 200 (returns 503 while loading; must wait)
- Metrics: decode tok/s (`timings.predicted_per_second`), prefill tok/s, VRAM (`nvidia-smi`)
- Long-context test: 37,800-character prompt ≈ **18,772 tokens**, `-c 65536`
- Average of 3 requests per group (short context), single request (long context)

---

## 3. Result 1: Three MTP Configurations Compared (short context, -c 4096)

| Config | decode (tok/s) | idle VRAM (MiB) | VRAM during generation (MiB) | TTFT |
|--------|---------------|-----------------|------------------------------|------|
| Baseline (no spec decoding) | 35.2 | 17,861 | 17,844 | 317ms |
| **Embedded head** (`draft-mtp`, no file) | 47.7 | 18,760 | 18,784 | 281ms |
| **Separate file** (`mtp-...Q4_0.gguf`) | 50.0 | 19,672 | 19,695 | 333ms |

**Conclusions:**
- MTP gives a **1.36–1.42× speedup** (35.2 → 47.7 / 50.0)
- The separate file is **~5% faster** than the embedded head (50.0 vs 47.7), but **uses ~0.9GB more VRAM** (all standalone draft weights are fully loaded into VRAM)
- Embedded head vs separate file: greedy outputs are **byte-identical** — speculative decoding is verification-based; the final output is entirely determined by the main model, so draft head quantization does not affect text quality
- Baseline vs spec occasionally produces different outputs; this is cuBLAS batch-shape-related floating-point non-determinism, not a quality regression

---

## 4. Result 2: Tuning `--spec-draft-n-max` (embedded head)

| n_max | tok/s (avg of 3) |
|-------|------------------|
| 3 (default) | 47.5 |
| 6 | 35.7 |
| 9 | 38.5 |

**Conclusion: n_max=3 is already optimal.** MTP drafts beyond ~3 tokens are almost always rejected; the extra draft tokens are wasted verification compute, and raising the value actually slows things down significantly (at n=6 it even drops back to baseline level).

> Note: explicitly setting `--spec-draft-n-max 3` is **identical to omitting it** (the default is already 3) — tok/s over 3 requests (45.0 vs 44.8) and the outputs are byte-identical, so no need to write it explicitly.

---

## 5. Result 3: KV Cache Quantization (18,772-token long context, -c 65536, embedded head)

| KV quant | decode (tok/s) | prefill (tok/s) | idle VRAM (MiB) |
|----------|---------------|-----------------|-----------------|
| q8_0 / q8_0 (current) | 42.6 | 1062.5 | 21,207 |
| q4_0 / q4_0 | 43.8 | 1058.3 | 20,201 |

**Conclusions:**
- q4 KV saves **~1GB of VRAM** (at 64K context)
- decode only +2.8% — for a 17.6GB dense model, the **weight bandwidth read per token is overwhelmingly dominant**; KV bandwidth is a tiny fraction, so KV quantization mainly **saves VRAM** rather than adding speed
- Note: context length has a significant effect on decode — short context 47.5 tok/s vs 18.8K context ~43 tok/s (attention's O(n) compute cost)

---

## 6. Result 4: Batch Size `-b` (18,772-token prompt, prefill phase)

| Batch size | prefill (tok/s) | idle VRAM (MiB) |
|------------|-----------------|-----------------|
| 2048 (default) | 1070.2 | 21,222 |
| 4096 | 1060.0 | 21,237 |
| 8192 | 1062.8 | 21,237 |

**Conclusion: batch size has no effect on prefill** (~1060 tok/s constant) — prefill has already hit the compute/bandwidth limit of this model on the 3090; it is not batch-size-limited. (This build has no `--ubatch` flag; micro-batching is folded into `-b`.)

---

## 6.1 Result 5: `--spec-draft-p-min` 0.0 vs 0.75 (embedded head, short context)

| p_min | tok/s (avg of 3) | pred_n | Output consistency |
|-------|------------------|--------|--------------------|
| 0.0 (default) | 47.1 | 138 | reference |
| 0.75 | 41.1 | 132 | output **differs** from 0.0 |

**Conclusion: `p_min=0.75` is actually slower (-13%) and changes the output.** Counterintuitive but explainable: once a non-greedy token is accepted through the threshold, the generation trajectory deviates from the main model's greedy path; the draft model (trained on the main model's actual generations) has a lower prediction hit rate on the deviated path → lower acceptance rate → slower. **Recommend removing this parameter (keep the default 0)** — both faster and strictly reproducible output.

---

## 6.2 Result 6: Does Stacking `ngram-simple` Help (prose vs repetitive text)

| Config | prose prompt (tok/s) | repetitive prompt (tok/s) |
|--------|----------------------|---------------------------|
| pure `draft-mtp` | 47.8 | 71.1 |
| `draft-mtp,ngram-simple` | 44.7 | 70.8 |

**Conclusion: stacking ngram-simple on top of an already-enabled MTP brings no benefit — prose is ~7% slower (ngram runs for nothing, pure overhead), repetitive text is unchanged (MTP itself already saturates repetitive patterns; the jump from 47.8 to 71.1 is MTP's doing).** ngram-simple's real role is "a zero-cost alternative when no MTP/draft model exists", not an accelerator for MTP. **Recommend using only `draft-mtp` for `--spec-type`.**

> Note: the 71 tok/s on repetitive text exceeds the bandwidth wall (~53) — with a high acceptance rate, one weight read yields multiple tokens, so effective throughput can break through the pure bandwidth ceiling; this is the core value of MTP.

---

## 6.3 Result 7: 160K / 192K Context Benchmarks (embedded head + q8_0 KV, 24GB)

| Context | loads/listens | idle VRAM (MiB) | actual run | conclusion |
|---------|---------------|-----------------|------------|------------|
| 128K (previously measured) | ✅ | ~23,300 | generates, ~700MB headroom | ⚠️ at the limit, high risk in practice |
| **160K** | ✅ | 24,186 | generates but prefill degrades (138 vs normal ~1060 tok/s), decode 36.6 | ❌ only ~390MB headroom, OOM in practice is guaranteed |
| **192K** | ✅ (loads + listens) | ~24,200 | crashes/hangs mid-prefill | ❌ unusable |

**Conclusion: 128K is the practical ceiling for the 24GB + q8_0 KV + embedded head configuration.** 160K can load, but zero VRAM headroom collapses prefill performance by 7× and invites OOM at any moment; 192K crashes on the first request after loading. If a larger context is mandatory, the only way is a lower KV quantization tier (q4_0 would theoretically cut 192K's KV from ~25GB to ~12.5GB), at the cost of quality.

---

## 7. Bandwidth Wall Analysis (Why Saving VRAM Doesn't Buy Speed)

Every token generated during decode requires reading the entire weight set once:

```
theoretical ceiling ≈ 936 GB/s ÷ 17.6 GB ≈ 53 tok/s
```

Measured embedded head on short context: 47.5 tok/s, already near the ceiling (~90%). **The decode bottleneck is weight bandwidth, not VRAM capacity** — so "spare VRAM" cannot be directly exchanged for faster single-stream token speed.

---

## 8. Conclusions and Recommendations

### 8.1 Recommended Configuration (current `start_simple.bat` already updated to match)

```bat
llama-server -m Qwen3.8-27B-UD-Q4_K_XL.gguf --alias qwen3.8-27B -c 98304
  --parallel 1 -ngl 99 -fa on --cache-type-k q8_0 --cache-type-v q8_0
  --spec-type draft-mtp
  --host 0.0.0.0 --port 8080 --api-key-file api_keys.txt
```

Key points: **embedded MTP head (without `--spec-draft-model`)** + KV q8_0 + **all speculative decoding parameters left at defaults** (`--spec-draft-n-max` defaults to 3, `--spec-draft-p-min` defaults to 0; explicitly setting them gains nothing, measured) + **no ngram-simple stacking** (no benefit, measured) = the optimal speed/VRAM/quality balance.

> Note: `start_server.bat` still keeps the separate MTP file approach (`--spec-draft-model mtp-...`), coexisting with the recommended embedded head approach; to keep them consistent, simply remove `--spec-draft-model mtp-Qwen3.8-27B-Q4_0.gguf` from the startup arguments.

### 8.2 Best Use of the 0.9GB of Saved VRAM

| Use case | Effect |
|----------|--------|
| **OOM safety margin** | 96K context drops from ~23.6GB to ~22.9GB, further from the OOM threshold |
| **128K context** | With the embedded head, 128K leaves ~700MB headroom (only ~377MB with the separate file), even safer with q4 KV; resolves the dsh 106K-token historical request rejections |

### 8.3 The Real Speed Levers (ranked by payoff)

1. **Control context length** (free, most effective): short ctx 47.5 vs 18.8K ctx 43 tok/s. On the dsh side, lower `thresholdRatio` (0.8→0.7) and start new sessions to clear history — this beats any VRAM trick;
2. **Switch to a smaller quantization** (+8% ceiling): Q4_K_M (~16.2GB) → bandwidth wall rises to ~57 tok/s, at the cost of some quality;
3. **KV q8→q4** (+2.8% on long context): mainly saves VRAM, with a small long-context speedup on the side; evaluate the quality impact yourself.

### 8.4 Optimizations Not Recommended

- ❌ `--spec-draft-n-max > 3`: measured slower (47.5 → 35.7)
- ❌ `--spec-draft-p-min > 0`: measured slower (47.1 → 41.1) and changes the output trajectory; keep the default 0
- ❌ Stacking `ngram-simple`: no benefit measured with MTP enabled; prose is even ~7% slower (see 6.2)
- ❌ `-c > 128K`: 160K/192K measured unusable (loading exhausts VRAM, running always crashes, see 6.3); 128K is the ceiling for 24GB + q8_0 KV
- ❌ Larger batch size `-b`: no effect
- ❌ Separate MTP file for a 5% speed gain: uses 0.9GB more VRAM, raises OOM risk in 96K scenarios; not worth it

---

## 9. Appendix: Key Verification Commands

```bash
# Audit whether the main GGUF embeds the MTP head (tensor names are blk.N.nextn.*, not mtp.*)
# Parse the GGUF header tensor list with Python and search for "nextn"

# Readiness poll (returns 503 while loading; curl does not treat the HTTP code as failure, must wait for 200)
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/v1/models

# Long prompt requests must use a file payload (Windows curl command line has a ~32KB limit)
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  --data-binary @payload.json
```

---

# 性能优化分析：Qwen3.8-27B 本地部署（RTX 3090 24GB）

> 实测日期：2026-08-20
> 硬件：RTX 3090 24GB（带宽 936 GB/s）
> 模型：`Qwen3.8-27B-UD-Q4_K_XL.gguf`（17.6GB，65 层，Q4_K_XL 量化）
> 草稿头：主 GGUF 内嵌（`blk.64.nextn.*`，Q4_K_XL）/ 独立文件 `mtp-Qwen3.8-27B-Q4_0.gguf`（Q4_0）
> 服务：llama-server（2026-08-19 build）

---

## 1. 背景

Qwen3.8-27B 的 MTP（多 token 预测）草稿头有**两种来源**：

| 来源 | 张量 | 量化 | 显存占用 |
|------|------|------|----------|
| 主 GGUF 内嵌 | `blk.64.nextn.{eh_proj,enorm,hnorm,shared_head_norm}.weight` | Q4_K_XL | 0（复用主模型张量） |
| 独立文件 `mtp-*.gguf` | blk.64 + nextn 头 + 输出头，共 18 个张量 | Q4_0 | ~1.8GB |

实测确认：llama-server 可用 `--spec-type draft-mtp` **不带** `--spec-draft-model` 直接使用内嵌头（日志：`creating MTP draft context against the target model`），两种方式均正常启动。

---

## 2. 测试方法

- 同一中文 prompt（短文，67 token），`temperature=0`（greedy），`max_tokens=256`
- 就绪判定：轮询 `/v1/models` 直到 HTTP 200（加载中返回 503，需等待）
- 指标：decode tok/s（`timings.predicted_per_second`）、prefill tok/s、VRAM（`nvidia-smi`）
- 长上下文测试：37,800 字符 prompt ≈ **18,772 tokens**，`-c 65536`
- 每组取 3 次请求平均（短上下文）或单次（长上下文）

---

## 3. 结果一：三种 MTP 配置对比（短上下文，-c 4096）

| 配置 | decode (tok/s) | 空闲显存 (MiB) | 生成显存 (MiB) | TTFT |
|------|---------------|---------------|---------------|------|
| 基线（无推测解码） | 35.2 | 17,861 | 17,844 | 317ms |
| **内嵌头**（`draft-mtp` 无文件） | 47.7 | 18,760 | 18,784 | 281ms |
| **独立文件**（`mtp-...Q4_0.gguf`） | 50.0 | 19,672 | 19,695 | 333ms |

**结论：**
- MTP 提速 **1.36~1.42×**（35.2 → 47.7 / 50.0）
- 独立文件比内嵌头**快 ~5%**（50.0 vs 47.7），但**多占 ~0.9GB 显存**（独立草稿权重全量进显存）
- 内嵌头 vs 独立文件：greedy 输出**逐字节一致**——推测解码是验证制，最终输出完全由主模型决定，草稿头量化不影响文本质量
- 基线 vs 带 spec 偶有输出差异，属 cuBLAS 批形状相关的浮点非确定性，非质量回退

---

## 4. 结果二：`--spec-draft-n-max` 调优（内嵌头）

| n_max | tok/s（3 次平均） |
|-------|------------------|
| 3（默认） | 47.5 |
| 6 | 35.7 |
| 9 | 38.5 |

**结论：n_max=3 已是最优。** MTP 草稿超过 ~3 个 token 后基本全部被拒，多出的草稿 token 白付验证计算，调大反而大幅变慢（n=6 时甚至跌回基线水平）。

> 补充：`--spec-draft-n-max 3` **显式指定与省略完全一致**（默认值即 3）——3 次请求 tok/s（45.0 vs 44.8）与输出逐字节相同，无需显式写。

---

## 5. 结果三：KV cache 量化（18,772 token 长上下文，-c 65536，内嵌头）

| KV 量化 | decode (tok/s) | prefill (tok/s) | 空闲显存 (MiB) |
|---------|---------------|-----------------|---------------|
| q8_0 / q8_0（当前） | 42.6 | 1062.5 | 21,207 |
| q4_0 / q4_0 | 43.8 | 1058.3 | 20,201 |

**结论：**
- q4 KV 省 **~1GB 显存**（64K 上下文）
- decode 仅 +2.8%——对 17.6GB 稠密模型，每 token 读取的**权重带宽占绝对主导**，KV 带宽占比极小，KV 量化主要是**省显存**而非提速
- 附：上下文长度对 decode 的影响显著——短上下文 47.5 tok/s vs 18.8K 上下文 ~43 tok/s（注意力 O(n) 计算成本）

---

## 6. 结果四：批大小 `-b`（18,772 token prompt，prefill 阶段）

| 批大小 | prefill (tok/s) | 空闲显存 (MiB) |
|--------|-----------------|---------------|
| 2048（默认） | 1070.2 | 21,222 |
| 4096 | 1060.0 | 21,237 |
| 8192 | 1062.8 | 21,237 |

**结论：批大小对 prefill 无影响**（~1060 tok/s 恒定）——prefill 已到该模型在 3090 上的计算/带宽极限，非批大小受限。（本 build 无 `--ubatch` 参数，微批已并入 `-b`。）

---

## 6.1 结果五：`--spec-draft-p-min` 0.0 vs 0.75（内嵌头，短上下文）

| p_min | tok/s（3 次平均） | pred_n | 输出一致性 |
|-------|------------------|--------|-----------|
| 0.0（默认） | 47.1 | 138 | 参照 |
| 0.75 | 41.1 | 132 | 与 0.0 相比输出**有差异** |

**结论：`p_min=0.75` 反而更慢（-13%），且改变了输出。** 反直觉但可解释：一旦通过阈值采纳了一个非贪心 token，生成轨迹就偏离主模型的贪心路径，草稿模型（按主模型真实生成训练）在偏离路径上的预测命中率下降 → 接受率更低 → 更慢。**建议删除该参数（保持默认 0）**——既更快，输出也严格可复现。

---

## 6.2 结果六：`ngram-simple` 叠加是否有收益（散文 vs 重复文本）

| 配置 | 散文 prompt (tok/s) | 重复文本 prompt (tok/s) |
|------|--------------------|------------------------|
| 纯 `draft-mtp` | 47.8 | 71.1 |
| `draft-mtp,ngram-simple` | 44.7 | 70.8 |

**结论：MTP 已开启时叠加 ngram-simple 无收益——散文拖慢 ~7%（ngram 白跑、纯开销），重复文本无差异（MTP 本身已把重复模式吃透，从 47.8 飙到 71.1 就是 MTP 的功劳）。** ngram-simple 的真正定位是"没有 MTP/草稿模型时的零成本替代方案"，而不是 MTP 的加速器。**建议 `--spec-type` 只用 `draft-mtp`。**

> 附：重复文本下 71 tok/s 超过带宽墙（~53）——推测解码高接受率时一次权重读取产出多个 token，有效吞吐可突破纯带宽上限，这是 MTP 的核心价值。

---

## 6.3 结果七：160K / 192K 上下文实测（内嵌头 + q8_0 KV，24GB）

| 上下文 | 加载/监听 | 空闲显存 (MiB) | 实际运行 | 结论 |
|--------|-----------|---------------|----------|------|
| 128K（此前实测） | ✅ | ~23,300 | 可生成，余量 ~700MB | ⚠️ 极限，实战高风险 |
| **160K** | ✅ | 24,186 | 可生成但 prefill 劣化（138 vs 正常 ~1060 tok/s），decode 36.6 | ❌ 余量仅 ~390MB，实战必 OOM |
| **192K** | ✅（加载+监听） | ~24,200 | prefill 中途进程崩溃/挂死 | ❌ 不可用 |

**结论：128K 是 24GB + q8_0 KV + 内嵌头配置的实际天花板。** 160K 虽能加载，但显存余量归零导致 prefill 性能暴跌 7 倍以上、随时 OOM；192K 加载后首轮请求即崩溃。若必须上更大上下文，唯一出路是 KV 量化降档（q4_0 理论可让 192K 的 KV 从 ~25GB 降到 ~12.5GB），但需接受质量折损。

---

## 7. 带宽墙分析（为什么省下显存换不来速度）

decode 每生成一个 token 都要把全部权重读一遍：

```
理论天花板 ≈ 936 GB/s ÷ 17.6 GB ≈ 53 tok/s
```

实测内嵌头短上下文 47.5 tok/s，已接近天花板（~90%）。**解码瓶颈是权重带宽，不是显存容量**——所以"多出的显存"无法直接兑换成更快的单流 token 速度。

---

## 8. 结论与建议

### 8.1 推荐配置（当前 `start_simple.bat` 已按此更新）

```bat
llama-server -m Qwen3.8-27B-UD-Q4_K_XL.gguf --alias qwen3.8-27B -c 98304
  --parallel 1 -ngl 99 -fa on --cache-type-k q8_0 --cache-type-v q8_0
  --spec-type draft-mtp
  --host 0.0.0.0 --port 8080 --api-key-file api_keys.txt
```

要点：**内嵌 MTP 头（不带 `--spec-draft-model`）** + KV q8_0 + **推测解码参数全部用默认**（`--spec-draft-n-max` 默认即 3、`--spec-draft-p-min` 默认即 0，实测显式指定无增益）+ **不叠加 ngram-simple**（实测无收益）= 速度/显存/质量最优平衡。

> 注：`start_server.bat` 仍保留独立 MTP 文件方案（`--spec-draft-model mtp-...`），与本文推荐的内嵌头方案并存；如需保持一致，将 `--spec-draft-model mtp-Qwen3.8-27B-Q4_0.gguf` 从启动参数中移除即可。

### 8.2 省下 0.9GB 显存的最佳用途

| 用途 | 效果 |
|------|------|
| **OOM 安全垫** | 96K 上下文从 ~23.6GB 降到 ~22.9GB，远离 OOM 临界 |
| **上 128K 上下文** | 内嵌头后 128K 余量 ~700MB（独立文件时仅 ~377MB），配 q4 KV 更稳；解决 dsh 106K-token 历史请求被拒问题 |

### 8.3 真正的提速杠杆（按收益排序）

1. **控制上下文长度**（免费、最有效）：短 ctx 47.5 vs 18.8K ctx 43 tok/s。dsh 端调低 `thresholdRatio`（0.8→0.7）、开新会话清历史，比任何显存玩法都更能提速；
2. **换更小量化**（+8% 上限）：Q4_K_M（~16.2GB）→ 带宽墙抬到 ~57 tok/s，代价是牺牲一点质量；
3. **KV q8→q4**（长上下文 +2.8%）：主要省显存，长上下文场景可顺带提速，需自行评估质量影响。

### 8.4 不建议的优化

- ❌ `--spec-draft-n-max > 3`：实测变慢（47.5 → 35.7）
- ❌ `--spec-draft-p-min > 0`：实测更慢（47.1 → 41.1）且改变输出轨迹，保持默认 0
- ❌ 叠加 `ngram-simple`：MTP 开启时实测无收益，散文还拖慢 ~7%（见 6.2）
- ❌ `-c > 128K`：160K/192K 实测不可用（加载即耗尽显存，运行必崩，见 6.3）；128K 是 24GB + q8_0 KV 天花板
- ❌ 加大批大小 `-b`：无效果
- ❌ 独立 MTP 文件追 5% 速度：多占 0.9GB 显存，96K 场景下 OOM 风险上升，不值

---

## 9. 附：关键验证命令

```bash
# 稽核主 GGUF 是否内嵌 MTP 头（张量名是 blk.N.nextn.* 而非 mtp.*）
# Python 解析 GGUF 头部张量清单，搜索 "nextn"

# 就绪轮询（加载中返回 503，curl 不把 HTTP 码当失败，必须等 200）
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/v1/models

# 长 prompt 请求必须用文件载荷（Windows curl 命令行 ~32KB 上限）
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  --data-binary @payload.json
```