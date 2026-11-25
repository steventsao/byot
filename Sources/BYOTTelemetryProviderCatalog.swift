// Generated from https://models.dev/api.json on 2026-11-25, merged with the
// earlier hand-kept list and the provider ids OpenCode ships that models.dev
// does not list (claude-agent, ollama, vllm). OpenCode 2's provider list
// (`GET /api/provider`, `Provider.Info`) has no field that says whether a
// provider came from the catalog or from the user's config, so this public
// list is what keeps a self-named provider reporting as `other`.

extension BYOTTelemetryOpenCode {
    /// Public provider ids: the models.dev catalog plus OpenCode's built-ins.
    static let knownProviders: Set<String> = [
        "302ai", "abacus", "abliteratedllm", "abliteration-ai", "above", "adaption", "adzuki", "agentrouter",
        "agnes", "ai-router", "ai21", "aiand", "aigrow", "aihubmix", "aimlapi", "ainetcafe", "aipg",
        "aistupidlevel", "aixy", "aki-io", "alibaba", "alibaba-cn", "alibaba-coding-plan", "alibaba-coding-plan-cn",
        "alibaba-token-plan", "alibaba-token-plan-cn", "amazon-bedrock", "ambient", "amd", "anonrouter",
        "anthropic", "anyapi", "apiko", "arcee", "atomic-chat", "augure", "auriko", "autarcho", "azure",
        "azure-cognitive-services", "bailing", "baseten", "bee", "berget", "blueclaw", "bothub", "boundless",
        "bumo", "byteplus", "cedarllm", "cerebras", "cheapaimodel", "cheapest-token", "cheapllm", "chutes",
        "clarifai", "claude-agent", "claudinio", "cline-pass", "cloudcode", "cloudferro-sherlock",
        "cloudflare-ai-gateway", "cloudflare-workers-ai", "cohere", "commandcode", "concentrate", "confidential-ai",
        "coralbricks", "cortecs", "crossmodel", "crusoe", "daoxe", "databricks", "deepinfra", "deepseek",
        "digitalocean", "dinference", "dothoosh", "doubleword", "drun", "ebcloud", "echo", "edenai", "empiriolabs",
        "engy", "entrim", "evroc", "ezkielyna", "fastrouter", "fiftyx", "fireworks-ai", "fortytwo", "freemodel",
        "frequency", "friendli", "frogbot", "gisoo", "github-copilot", "gitlab", "gmicloud", "google",
        "google-vertex", "google-vertex-anthropic", "graphn", "greenpt", "groq", "helicone", "hetzner", "hopper",
        "hostinger-router", "hpc-ai", "huawei-maas", "hubris", "huggingface", "humain", "hyper", "iflowcn",
        "impossibl", "inception", "inceptron", "inco", "infer", "inferall", "inference", "inference-coop",
        "inferenceapis", "inferris", "infersia", "inferx", "infomaniak", "io-net", "isoquant", "iteracompute",
        "jad-ai", "jalapeno", "jiekou", "joingonka", "jzstoken", "keln", "kenari", "kilo", "kimi-code-plan-cn",
        "kimi-code-plan-global", "kitani", "klavo", "klokintegration", "korouter", "kosmik",
        "kuae-cloud-coding-plan", "kunavo", "liquid", "lithosai", "llama", "llmgateway", "llmgateway-providers",
        "llmtech", "llmtr", "lmstudio", "logits", "longcat", "lowrouter", "lucidquery", "lyceum", "lynkr",
        "mallard", "meganova", "melious", "meragpt", "merge-gateway", "meta", "minimax", "minimax-cn",
        "minimax-cn-coding-plan", "minimax-coding-plan", "mistral", "mixlayer", "moark", "modal", "model-oracle-ai",
        "modelis", "modelscope", "modular", "moneo", "moonshotai", "moonshotai-cn", "morph", "munito", "munito-eu",
        "nan", "nano-gpt", "nearai", "nebius", "neon", "neosmith", "neuralwatt", "nodecode", "nokeep", "nova",
        "novita-ai", "nvidia", "oathbreaker", "obscurify", "oci", "ofox", "ollama", "ollama-cloud", "openai",
        "opencode", "opencode-go", "openreason", "openrouter", "opper", "orcarouter", "outerlabs", "ovhcloud",
        "paraloncloud", "pareto", "pendra", "perplexity", "perplexity-agent", "phala", "phase", "pioneer", "poe",
        "poolside", "powerspring", "primalabs", "prime", "privatemode-ai", "proxystacks", "qihang-ai", "qiniu-ai",
        "qvac", "rayline", "reflection", "refuseless", "regolo-ai", "requesty", "routing-run", "ruapi", "runcrate",
        "runinfra", "sagg", "sakana", "salad-cloud", "sambanova", "sandbase", "sap-ai-core", "sarvam", "scaleway",
        "scnet-token-plan", "scx-ai", "sensenova", "siliconflow", "siliconflow-cn", "snowflake-cortex", "sokkan",
        "sparrowcodes", "stackit", "standardcompute", "steadyrouter", "stepfun", "stepfun-ai",
        "stepfun-ai-step-plan", "stepfun-step-plan", "stepping-stone", "subconscious", "submodel", "superbot-gg",
        "synthetic", "synthorai", "teamorouter", "teapot-router", "tencent-coding-plan", "tencent-token-plan",
        "tencent-tokenhub", "tensorx", "tenstorrent", "the-grid-ai", "therouter", "thinkingmachines", "tinfoil",
        "toapis", "togetherai", "tokengo", "tokenify", "tokenlab", "tokenrouter", "tokenwatt", "trustedrouter",
        "trustedtokens", "umans-ai", "umans-ai-coding-plan", "unbiased", "uncensuredai", "unorouter",
        "unrestricted", "uplinkswitch", "upstage", "v0", "vancine", "venice", "vercel", "verda", "vispark",
        "vivgrid", "vllm", "volcengine", "volcengine-coding-plan", "vultr", "wafer.ai", "wallaby", "wally", "wandb",
        "watsonx", "watt", "xai", "xiaomi", "xiaomi-token-plan-ams", "xiaomi-token-plan-cn",
        "xiaomi-token-plan-sgp", "xpersona", "xxapi", "zai", "zai-coding-plan", "zeldoc", "zenifra", "zenmux",
        "zerogpu", "zhipuai", "zhipuai-coding-plan", "zro",
    ]
}
