"""Text embeddings: a local multilingual model by default, a hashing stand-in for tests."""

from __future__ import annotations

import hashlib
import math
import os
import re
from pathlib import Path
from typing import Protocol

DEFAULT_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
TOKEN = re.compile(r"\w+", re.UNICODE)


class Embedder(Protocol):
    name: str
    dim: int

    def embed(self, texts: list[str]) -> list[list[float]]: ...


class HashEmbedder:
    """Deterministic bag-of-words vectors: no model, no download. For tests and as a
    fallback where the real model cannot run; it only matches shared words."""

    def __init__(self, dim: int = 256) -> None:
        self.name = f"hash-{dim}"
        self.dim = dim

    def embed(self, texts: list[str]) -> list[list[float]]:
        out = []
        for text in texts:
            vec = [0.0] * self.dim
            for token in TOKEN.findall(text.lower()):
                digest = hashlib.blake2b(token.encode(), digest_size=4).digest()
                vec[int.from_bytes(digest, "little") % self.dim] += 1.0
            out.append(_normalize(vec))
        return out


class FastEmbedder:
    def __init__(self, model: str = DEFAULT_MODEL, cache_dir: Path | None = None) -> None:
        from fastembed import TextEmbedding

        self.name = model
        self._model = TextEmbedding(
            model_name=model, cache_dir=str(cache_dir) if cache_dir else None
        )
        self.dim = len(next(iter(self._model.embed(["dim"]))).tolist())

    def embed(self, texts: list[str]) -> list[list[float]]:
        return [_normalize(v.tolist()) for v in self._model.embed(texts, batch_size=32)]


class LazyEmbedder:
    """Loads the model on first use: a text-only search never pays for it."""

    def __init__(self, model: str, cache_dir: Path) -> None:
        self.name = model
        self._cache_dir = cache_dir
        self._inner: FastEmbedder | None = None

    def _load(self) -> FastEmbedder:
        if self._inner is None:
            self._inner = FastEmbedder(self.name, self._cache_dir)
        return self._inner

    @property
    def dim(self) -> int:
        return self._load().dim

    def embed(self, texts: list[str]) -> list[list[float]]:
        return self._load().embed(texts)


def get_embedder(kind: str | None = None) -> Embedder | None:
    """``fastembed`` (default), ``hash``, or ``none`` for a text-only index."""
    kind = (kind or os.environ.get("KB_EMBED") or "fastembed").lower()
    if kind == "none":
        return None
    if kind == "hash":
        return HashEmbedder()
    if kind == "fastembed":
        cache = os.environ.get("KB_MODEL_DIR") or str(Path.home() / ".cache" / "kb" / "models")
        return LazyEmbedder(os.environ.get("KB_EMBED_MODEL", DEFAULT_MODEL), Path(cache))
    raise ValueError(f"Unknown embedder {kind!r}: use fastembed, hash or none.")


def _normalize(vec: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vec))
    return [x / norm for x in vec] if norm else vec
