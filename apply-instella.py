#!/usr/bin/env python3
"""Add Instella-MoE support to the pinned llama.cpp.

Upstream llama.cpp does not know AMD's Instella-MoE; the community fork
(csabakecskemeti/llama.cpp, branch instella-moe) carries it in one commit
that adds a model file and registers the architecture in four places.

This copies that model file across and makes the same four registrations, so
the engine keeps the pinned llama.cpp (with its expert-streaming hook) and
gains the model. The conversion scripts the fork also touched are for
huggingface-to-gguf conversion, not for running a model, so they are left
alone.

    python3 apply-instella.py [path-to-llama.cpp]
"""

import shutil
import sys
from pathlib import Path

LL = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("third_party/llama.cpp").resolve()
HERE = Path(__file__).resolve().parent
MODEL_SOURCE = HERE / "patches" / "instella-moe.cpp"

failed = []


def patch(rel, old, new, mode="after", where=None):
    """Edit one file.

    mode "after"  - put `new` right after `old`
    mode "before" - put `new` right before `old`
    mode "replace"- swap `old` for `new`
    where         - only search inside the function whose signature contains it
    """
    path = LL / rel
    text = path.read_text(encoding="utf-8")
    start = 0
    if where:
        pos = text.find(where)
        if pos < 0:
            failed.append(f"{rel}: function {where!r} not found")
            print(f"  {rel}: FUNCTION NOT FOUND {where!r}")
            return
        start = pos
    pos = text.find(old, start)
    if pos < 0:
        failed.append(f"{rel}: anchor {old.strip()[:50]!r} not found")
        print(f"  {rel}: ANCHOR NOT FOUND {old.strip()[:50]!r}")
        return
    # already done? look at the place the change would go, not at the whole file
    if mode == "after" and text[pos + len(old) :].startswith(new):
        print(f"  {rel}: already patched")
        return
    if mode == "before" and text[max(0, pos - len(new)) : pos].endswith(new):
        print(f"  {rel}: already patched")
        return
    if mode == "replace" and text[pos : pos + len(new)] == new:
        print(f"  {rel}: already patched")
        return
    if mode == "replace":
        out = text[:pos] + new + text[pos + len(old) :]
    elif mode == "before":
        out = text[:pos] + new + text[pos:]
    else:
        out = text[: pos + len(old)] + new + text[pos + len(old) :]
    path.write_text(out, encoding="utf-8")
    print(f"  {rel}: patched")


# 1. the model implementation itself
dst = LL / "src" / "models" / "instella-moe.cpp"
if dst.exists():
    print("  src/models/instella-moe.cpp: already there")
else:
    if not MODEL_SOURCE.exists():
        sys.exit(f"missing {MODEL_SOURCE}")
    shutil.copyfile(MODEL_SOURCE, dst)
    print("  src/models/instella-moe.cpp: copied")

# 2. the architecture enum (before the sentinel)
patch(
    "src/llama-arch.h",
    "    LLM_ARCH_UNKNOWN,\n",
    "    LLM_ARCH_INSTELLA_MOE,\n",
    mode="before",
)

# 3. the name the gguf file carries
patch(
    "src/llama-arch.cpp",
    '    { LLM_ARCH_UNKNOWN,          "(unknown)"        },',
    '    { LLM_ARCH_INSTELLA_MOE,     "instella-moe"     },\n',
    mode="before",
)

# 4. the architecture uses the sm tensor path
patch(
    "src/llama-arch.cpp",
    "        case LLM_ARCH_DOTS3NOTE:\n",
    "        case LLM_ARCH_INSTELLA_MOE:\n",
    where="bool llm_arch_supports_sm_tensor",
)

# 5. the model class the loader builds
patch(
    "src/llama-model.cpp",
    "        case LLM_ARCH_DEEPSEEK4:\n            return new llama_model_deepseek4(params);\n",
    "        case LLM_ARCH_INSTELLA_MOE:\n            return new llama_model_instella_moe(params);\n",
    where="llama_model * llama_model_mapping",
)

# 6. the extra fields the model prints
patch(
    "src/llama-model.cpp",
    "arch == LLM_ARCH_HY_V4) {",
    "arch == LLM_ARCH_HY_V4 || arch == LLM_ARCH_INSTELLA_MOE) {",
    mode="replace",
    where="void llama_model::print_info",
)

# 7. the rope type
patch(
    "src/llama-model.cpp",
    "        case LLM_ARCH_NANBEIGE:\n",
    "        case LLM_ARCH_INSTELLA_MOE:\n",
    where="llama_rope_type llama_model_rope_type",
)

# 8. the class declaration
patch(
    "src/models/models.h",
    "struct llama_model_deepseek32 : public llama_model_base {",
    """struct llama_model_instella_moe : public llama_model_base {
    llama_model_instella_moe(const struct llama_model_params & params) : llama_model_base(params) {}
    void load_arch_hparams(llama_model_loader & ml) override;
    void load_arch_tensors(llama_model_loader & ml) override;

    struct graph : public llm_graph_context {
        graph(const llama_model & model, const llm_graph_params & params);
    };

    std::unique_ptr<llm_graph_context> build_arch_graph(const llm_graph_params & params) const override;
};


""",
    mode="before",
)

if failed:
    print("\nnot everything applied:")
    for f in failed:
        print(f"  {f}")
    sys.exit(1)
print("\nInstella-MoE support is in place")
