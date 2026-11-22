# Guides

Step-by-step sample deployments. Each one starts from a cluster that meets [prerequisites.md](../prerequisites.md) (guide 01 also walks through that setup) and ends with a model answering through the Gateway.

| Guide | Deploys | Hardware | Needs |
| --- | --- | --- | --- |
| [01. First deployment](01-first-deployment.md) | Qwen3-32B on the optimized baseline, agentgateway | 4 × H100/H200 | — |
| [02. Bring your own model](02-bring-your-own-model.md) | Any HF model; MTP and draft-model speculative decoding; one-GPU nodes; pinned llm-d and vLLM versions | varies | — |
| [03. Tiered prefix cache](03-tiered-prefix-cache.md) | KV offload HBM → CPU RAM, GKE Gateway | 4 × H100/H200, 300 GiB RAM per replica | — |
| [04. P/D disaggregation](04-pd-disaggregation.md) | Prefill/decode split, then P/D + CPU tier (combo), then custom sizing | H200 + RDMA | LWS |
| [05. Wide expert parallelism](05-wide-ep.md) | DeepSeek-R1 wide-EP; GLM-5.2 wide-EP + P/D + tiered (upstream recipe) | 32–64 × H200, full-mesh RDMA | LWS |
| [06. Several models on one Gateway](06-multi-model-gateway.md) | Two models sharing one Gateway through IPP | — | IPP |
| [07. Gemma 4 P/D + tiered on G4](07-gemma-pd-tiered-g4.md) | P/D without RDMA, worked end to end including tuning | 3 × g4-standard-96 (RTX PRO 6000) | LWS |

Air-gapped cluster? Do [air-gapped.md](../air-gapped.md) steps 2–5 before the deploy step of any guide, and pass the same `-e <env>` to every command.

**Which strategy?**

| Your situation | Guide |
| --- | --- |
| Any dense model, chat or agentic traffic | 01, 02 |
| Long shared prefixes (system prompts, documents, sessions) that don't fit in HBM | 03 |
| Long prompts, short answers; TTFT and ITL tuned separately | 04 |
| Large MoE across nodes | 05 |
| Many models, one endpoint | 06 |

Every YAML sample marked `# profile: <path>` renders with the pipeline as written, and samples of profiles in `profiles/` are identical to those files: `docs/check-guide.sh` checks both.
