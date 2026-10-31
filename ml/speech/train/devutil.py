"""Device helpers so train.py / evaluate.py run unchanged on CUDA (Linux box) and MPS (Mac)."""
from __future__ import annotations
import torch


def pick_device(local_rank: int = 0) -> torch.device:
    if torch.cuda.is_available(): return torch.device("cuda", local_rank)
    if torch.backends.mps.is_available(): return torch.device("mps")
    return torch.device("cpu")


def synchronize(dev):
    if dev.type == "cuda": torch.cuda.synchronize(dev)
    elif dev.type == "mps": torch.mps.synchronize()


def empty_cache(dev):
    if dev.type == "cuda": torch.cuda.empty_cache()
    elif dev.type == "mps": torch.mps.empty_cache()


def mem_gb(dev) -> float:
    """MPS: driver-allocated now. CUDA: peak allocated since start."""
    if dev.type == "cuda": return torch.cuda.max_memory_allocated(dev) / 1e9
    if dev.type == "mps": return torch.mps.driver_allocated_memory() / 1e9
    return 0.0
