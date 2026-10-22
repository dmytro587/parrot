# Phonon-2 memory growth: fork Fermion and fix upstream

Last updated: 2026-10-08

Parrot runs Phonon-2 by spawning a long-lived **`fermion serve`** child (Python + MLX). A healthy baseline after load is often **~1 GB**; **monotonic growth during dictation** (e.g. 1.5 → 3.5 GB over several sentences) is not acceptable and is not fixed by restarting `fermion` after every few utterances.

The durable fix is in **`fermion-research`** (the `fermion` CLI), not in Parrot restart policy. Parrot can keep starting `fermion serve` as today; install a **fork** (or merged upstream release) of the Python package.

## Repos and packages


| What              | URL                                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------------------- |
| Source / issues   | [https://github.com/fermionresearch/phonon](https://github.com/fermionresearch/phonon)               |
| Issue tracker     | [https://github.com/fermionresearch/phonon/issues](https://github.com/fermionresearch/phonon/issues) |
| PyPI install name | `fermion-research` (`fermion` on PATH)                                                               |
| Phonon-2 weights  | [https://huggingface.co/FermionResearch/Phonon-2](https://huggingface.co/FermionResearch/Phonon-2)   |


Fork the **phonon** repo (confirm layout matches the `fermion-research` wheel), branch, patch, then install from your Git URL or a built wheel. Parrot uses whatever `fermion` is on `PATH`.

## What to change in the fork

Observed in **fermion-research 0.2.9** (Phonon-2 MLX + `serve`). Phonon-1’s MLX path already calls `mx.clear_cache()` in places; Phonion-2 + serve mostly does not — Parrot’s `parrot_fermion_boot` hook is a workaround, not a full fix.


| Area                            | Location (0.2.9)                                          | Intended change                                                                                              |
| ------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| After every HTTP dictation      | `fermion/server.py` → `SpeechEngine.transcribe_bytes`     | `finally:` call `mlx.core.clear_cache()` (optionally `mx.synchronize()` once)                                |
| Phonon-2 decode                 | `fermion/_speech/engine_phonon2.py`                       | Same after `_decode_single` / `model.generate`                                                               |
| Long / segmented audio          | `segment.transcribe_windows` and callers                  | `clear_cache` **per window**, not only at end of file                                                        |
| Hotwords (dictionary → fermion) | `fermion/_speech/hotwords.py`, `fast_decode.set_hotwords` | Cap caches; release `_mlx_tables` / `_device_tables` after decode; avoid unbounded growth when vocab changes |
| Peak at load (optional)         | Phonon-2 loader / `FERMION_P2_FAST`                       | Default without `dense16` (\~400 MB peak); Parrot already sets `FERMION_P2_FAST=tdt16` on the child env      |


## Install the fork for local Parrot testing

```sh
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 -m pip install -e ~/Documents/www/projects/phonon
which fermion   # ~/.local/bin/fermion
fermion --version
```

The fork vendors `fermion-research` 0.2.9 sources at the repo root (`fermion/`, `pyproject.toml`). Parrot does not need code changes if `fermion` resolves to that editable install.

## How to verify the fix

### Goal

- **Before:** RSS or Activity Monitor memory **rises monotonically** across many short dictations (similar to 1.5 → 3.5 GB in one session).
- **After:** footprint **plateaus** or small sawtooth; idle after dictation should not keep climbing without new requests.

### Repro script (serve already running)

1. Start serve (or let Parrot load Phonon-2):
   ```sh
   export FERMION_CACHE_DIR="$HOME/Documents/www/projects/phonon/.cache/fermion"
   export FERMION_P2_FAST=tdt16
   fermion serve phonon-2 --host 127.0.0.1 --port 8765
   ```
2. Loop **20–50** POSTs to `/v1/audio/transcriptions` with the **same short WAV** (3–5 s), optional `hotwords` matching Parrot’s dictionary terms.
3. After each request, record:
   - process RSS (`ps -o rss= -p PID`), and/or
   - inside fermion if instrumented: `mlx.core.get_active_memory()`, `get_peak_memory()` (see `load_parakeet.py` receipts).
4. Plot request index vs memory against `fermion --version` and macOS arch.

Or from the fork (starts serve, loops, stops — cache stays under `phonon/.cache/fermion`):

```sh
cd ~/Documents/www/projects/phonon/scripts
python3.12 verify_serve_memory.py --wav /path/to/short.wav --n 40
python3.12 verify_serve_memory.py --wav /path/to/short.wav --n 35 --hotwords 'Term1,Term2' --port 8768
```

Use a **different `--port`** per run (or wait for the prior process to exit). If RSS prints **`0`**, the serve child died — the script exits non-zero and dumps the serve log tail.

**Fork measurements (2026-10-09, `FERMION_CACHE_DIR` under the phonon clone, `jfk.wav`, editable 0.2.9 + MLX cache fixes):**

| Scenario | Requests | Pattern |
| -------- | -------- | ------- |
| No hotwords | 40 | Warm-up spike (~736 MB RSS), then **~88–104 MB** for requests 16–40 (no monotonic climb) |
| Hotwords (`Kennedy,country,people`) | 32 | Warm-up ~606→291 MB, then **~155–205 MB** requests 15–32 (bounded; no GB-scale climb) |
| Back-to-back runs | — | Chaining two verifies without a new port can kill the second serve; treat RSS `0` as a harness error, not success |

`ps` RSS is smaller than Activity Monitor “Memory” for the same process; Parrot dictation checks should still use the real app process during **10+ sentences**.

### With Parrot

1. Quit and reopen Parrot after installing the fork.
2. Dictate **10+ short sentences**; watch the single Python/`fermion` process.
3. Stop dictating for **2–3 minutes** (idle sweep in Parrot’s boot hook may help cache only; a real fix should limit growth **during** dictation).

### What success does *not* mean

A fork cannot shrink a **hot loaded model** to ~500 MB. **~1 GB idle after load** is expected. The fix targets **session growth from yapping**, not removing the model from RAM.

## Parrot-side context (today)

- `PhononServer` sets `FERMION_P2_FAST=tdt16`, `PHONON_ENC=q8`, MLX cache limit, idle sweep via `~/Library/Application Support/parrot/phonon/python_boot/`.
- Quit Parrot should stop the owned `fermion` child; `PhononSupport.reapOrphanedServeProcesses()` cleans leftovers on next start.

See also [architecture.md](architecture.md) (Phonon-2 via loopback `fermion serve`).