# Installing the AI stack

Install the modules in the order below, one at a time with `module-manager module add <module>`,
or all at once with `module-manager add-stack ai` once #763 is built. Each module's
INSTALL.md says what you must do by hand. What the stack is and why: [README.md](README.md).

**Hardware.** Local AI is sized by accelerator memory and the model you want — see the
[GPU / VRAM guidance](../../hardware-selection.md#sizing-local-ai--gpu--vram-guidance). The
reference AI node is an AMD Ryzen AI MAX+ 395 ("Strix Halo") with 128 GB unified memory;
discrete GPUs work too.

**Serving locally: vllm-amd before litellm.** LiteLLM *integrates with* `vllm-amd:inference`
(#501) rather than depending on it: installed first, vLLM is wired into LiteLLM when LiteLLM
installs; installed later, it is wired in when it arrives. LiteLLM reads the served model live,
so vLLM must be up and serving at that moment — see [litellm/INSTALL.md](litellm/INSTALL.md).

**No local AI hardware?** LiteLLM can front remote models instead — convenient, less
sovereign. Any other OpenAI-compatible backend on your network (a vLLM or Ollama you already
run) can also be added as a provider.

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

Install order: a module is listed after every module of this stack it needs or integrates with.

| # | Module | Needs, in this stack | Integrates with, if installed | Needs, installed first |
|---|---|---|---|---|
| 1 | [vllm-amd](vllm-amd/INSTALL.md) | — | — | `backup:vm` (foundation), `cluster:lxc` (foundation) |
| 2 | [litellm](litellm/INSTALL.md) | — | `logging:logs` (foundation), `vllm-amd:inference` | `backup:vm` (foundation), `cluster:vm` (foundation), `identity:identity` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |
| 3 | [openwebui](openwebui/INSTALL.md) | `litellm:models` | `logging:logs` (foundation) | `backup:vm` (foundation), `cluster:vm` (foundation), `identity:identity` (foundation), `network:proxy` (foundation), `network:rules` (foundation), `templates:nixos` (foundation) |

<!-- END GENERATED MODULES -->
