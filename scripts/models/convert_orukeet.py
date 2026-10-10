# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.3.3", "safetensors==0.6.2"]
# ///
"""Converts Orukeet (oruk/orukeet, a Parakeet TDT 0.6B v3 fine-tune) to the MLX layout that
mlx-audio-swift's Parakeet loader reads, so brain-md can offer it as a speech model.

Orukeet ships a Transformers export (`model.safetensors`, ParakeetForTDT). Its tensors map one to
one onto mlx-community/parakeet-tdt-0.6b-v3, which has the same architecture and tokenizer: names
change, convolutions move their channel axis last, and the LSTM's two biases are summed. Nothing is
unpickled. Every tensor is checked against the reference's names and shapes before writing.

  uv run scripts/models/convert_orukeet.py --check-mapping   # headers only, no weights
  uv run scripts/models/convert_orukeet.py                   # downloads 2.5 GB, writes build/models/orukeet-mlx
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import struct
import sys
import urllib.request
from pathlib import Path

SOURCE = "oruk/orukeet"
SOURCE_REVISION = "b59c13a733fce5cf193230d0fa317ee7f145a108"
REFERENCE = "mlx-community/parakeet-tdt-0.6b-v3"
REFERENCE_REVISION = "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
# Copied from the reference: the NeMo config (with vocabulary) and tokenizer files the loader reads.
REFERENCE_FILES = ["config.json", "vocab.txt", "tokenizer.model", "tokenizer.vocab"]
SOURCE_FILES = ["LICENSE", "LICENSE-WEIGHTS", "NOTICE.md", "CITATION.cff"]

REPO_ROOT = Path(__file__).resolve().parents[2]


def url(repo: str, revision: str, name: str) -> str:
    return f"https://huggingface.co/{repo}/resolve/{revision}/{name}"


def safetensors_header(repo: str, revision: str, name: str = "model.safetensors") -> dict:
    """Reads only a safetensors file's JSON header with two HTTP range requests."""
    def fetch(start: int, end: int) -> bytes:
        request = urllib.request.Request(url(repo, revision, name), headers={"Range": f"bytes={start}-{end}"})
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    length = struct.unpack("<Q", fetch(0, 7))[0]
    header = json.loads(fetch(8, 7 + length))
    header.pop("__metadata__", None)
    return header


# Source (Transformers) name → reference (MLX) name. Order matters: the first match wins.
RENAMES: list[tuple[str, str]] = [
    (r"^decoder\.embedding\.", "decoder.prediction.embed."),
    (r"^decoder\.decoder_projector\.", "joint.pred."),
    (r"^encoder_projector\.", "joint.enc."),
    (r"^joint\.head\.", "joint.joint_net.2."),
    (r"^encoder\.subsampling\.layers\.(\d+)\.", r"encoder.pre_encode.conv.\1."),
    (r"^encoder\.subsampling\.linear\.", "encoder.pre_encode.out."),
    (r"\.conv\.norm\.", ".conv.batch_norm."),
    (r"\.self_attn\.q_proj\.", ".self_attn.linear_q."),
    (r"\.self_attn\.k_proj\.", ".self_attn.linear_k."),
    (r"\.self_attn\.v_proj\.", ".self_attn.linear_v."),
    (r"\.self_attn\.o_proj\.", ".self_attn.linear_out."),
    (r"\.self_attn\.relative_k_proj\.", ".self_attn.linear_pos."),
    (r"\.self_attn\.bias_u$", ".self_attn.pos_bias_u"),
    (r"\.self_attn\.bias_v$", ".self_attn.pos_bias_v"),
]
LSTM = re.compile(r"^decoder\.lstm\.(weight|bias)_(ih|hh)_l(\d+)$")


def plan(source: dict, reference: dict) -> dict[str, tuple[list[str], str]]:
    """For each reference tensor: the source tensors it's built from and how ("copy", "transpose", "sum")."""
    result: dict[str, tuple[list[str], str]] = {}
    for name, info in source.items():
        if name.endswith("num_batches_tracked"):
            continue
        if match := LSTM.match(name):
            kind, gate, layer = match.groups()
            prefix = f"decoder.prediction.dec_rnn.lstm.{layer}."
            if kind == "weight":
                result[prefix + ("Wx" if gate == "ih" else "Wh")] = ([name], "copy")
            else:
                inputs, _ = result.setdefault(prefix + "bias", ([], "sum"))
                inputs.append(name)
            continue
        target = name
        for pattern, replacement in RENAMES:
            target = re.sub(pattern, replacement, target)
        rank = len(info["shape"])
        result[target] = ([name], "transpose" if rank in (3, 4) else "copy")

    missing = sorted(set(reference) - set(result))
    extra = sorted(set(result) - set(reference))
    if missing or extra:
        sys.exit(f"mapping mismatch\n  missing: {missing[:10]}\n  unexpected: {extra[:10]}")
    for target, (inputs, operation) in result.items():
        shape = source[inputs[0]]["shape"]
        if operation == "transpose":
            # PyTorch conv weights keep channels second; MLX keeps them last.
            shape = [shape[0], *shape[2:], shape[1]]
        if shape != reference[target]["shape"]:
            sys.exit(f"shape mismatch for {target}: {shape} vs {reference[target]['shape']}")
    return result


def download(repo: str, revision: str, name: str, directory: Path) -> Path:
    """Downloads a file at a pinned revision and checks its size and LFS SHA-256 against the Hub API."""
    with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true", timeout=60) as r:
        siblings = {s["rfilename"]: s for s in json.load(r)["siblings"]}
    expected = siblings[name]
    path = directory / name
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading {repo}/{name} ({expected.get('size', 0) / 1e9:.2f} GB)", file=sys.stderr)
    digest = hashlib.sha256()
    with urllib.request.urlopen(url(repo, revision, name), timeout=60) as response, path.open("wb") as out:
        while chunk := response.read(1 << 22):
            digest.update(chunk)
            out.write(chunk)
    if (lfs := expected.get("lfs")) and lfs.get("sha256") != digest.hexdigest():
        sys.exit(f"checksum mismatch for {name}")
    return path


MODEL_CARD = """---
license: cc-by-sa-4.0
base_model: {source}
library_name: mlx
pipeline_tag: automatic-speech-recognition
tags: [mlx, parakeet, tdt, speech-recognition, multilingual]
language: [bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro, ru, sk, sl, es, sv, uk]
---

# Orukeet (MLX)

An MLX conversion of [{source}](https://huggingface.co/{source}) at revision `{source_revision}`,
for [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)'s Parakeet loader.

Orukeet is by Oruk AI (Nathan Roll, Irene Yi, Büşra Marşan, Vianney Grenez, Gabriel Stein,
Momcilo Mrkaic, Pavle Padjin, Vladimir Zeljkovic, Calbert Graham), fine-tuned from NVIDIA Parakeet
TDT 0.6B v3. See the original model card for benchmarks, citation and limitations.

## Changes

Format only, no retraining: tensors renamed to the MLX Parakeet layout, convolution weights moved
to channels-last, the LSTM's input and hidden biases summed, and weights stored as float16. The
NeMo config and tokenizer files come from [{reference}](https://huggingface.co/{reference})
(`{reference_revision}`), which has the same architecture and tokenizer.

## License

The weights are licensed under CC-BY-SA-4.0, like the original; this conversion is shared under
the same license. The original LICENSE, LICENSE-WEIGHTS and NOTICE.md are included.
"""


def convert(output: Path, work: Path) -> None:
    import numpy as np
    from safetensors.numpy import load_file, save_file

    reference = safetensors_header(REFERENCE, REFERENCE_REVISION)
    source_header = safetensors_header(SOURCE, SOURCE_REVISION)
    mapping = plan(source_header, reference)

    weights = load_file(download(SOURCE, SOURCE_REVISION, "model.safetensors", work))
    converted = {}
    for target, (inputs, operation) in mapping.items():
        if operation == "sum":
            tensor = sum(weights[name] for name in inputs)
        elif operation == "transpose":
            tensor = np.moveaxis(weights[inputs[0]], 1, -1)
        else:
            tensor = weights[inputs[0]]
        converted[target] = np.ascontiguousarray(tensor.astype(np.float16))

    output.mkdir(parents=True, exist_ok=True)
    save_file(converted, str(output / "model.safetensors"), metadata={"format": "mlx"})
    for name in REFERENCE_FILES:
        shutil.copy(download(REFERENCE, REFERENCE_REVISION, name, work / "reference"), output / name)
    for name in SOURCE_FILES:
        shutil.copy(download(SOURCE, SOURCE_REVISION, name, work / "source"), output / name)
    (output / "README.md").write_text(MODEL_CARD.format(
        source=SOURCE, source_revision=SOURCE_REVISION, reference=REFERENCE, reference_revision=REFERENCE_REVISION))
    print(f"wrote {output}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check-mapping", action="store_true", help="verify names and shapes from file headers only")
    parser.add_argument("--output", type=Path, default=REPO_ROOT / "build/models/orukeet-mlx")
    parser.add_argument("--work", type=Path, default=REPO_ROOT / "build/models/orukeet-source")
    args = parser.parse_args()

    if args.check_mapping:
        mapping = plan(safetensors_header(SOURCE, SOURCE_REVISION), safetensors_header(REFERENCE, REFERENCE_REVISION))
        print(f"mapping OK: {len(mapping)} tensors match {REFERENCE}")
        return
    convert(args.output, args.work)
    print("\nTo publish it under your Hugging Face account (sign in with `hf auth login` first):")
    print(f"  hf upload <your-account>/orukeet-mlx {args.output} . --repo-type model")


if __name__ == "__main__":
    main()
