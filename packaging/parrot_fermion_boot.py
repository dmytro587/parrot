"""Loaded by Parrot's fermion child via a .pth on PYTHONPATH (see PhononServeEnvironment).

- ``set_cache_limit`` from ``PARROT_PHONON_MLX_CACHE_LIMIT_MB`` (default 256).
- ``clear_cache`` after each transcription (HTTP / serve path).
- Background idle sweep every ``PARROT_PHONON_IDLE_SWEEP_SEC`` (default 45) when no decode runs.
"""
from __future__ import annotations

import os
import threading
import time

_BACKENDS_PATCHED = False
_SPEECH_PATCHED = False
_PHONON2_PATCHED = False
_SWEEPER_STARTED = False

_active_decodes = 0
_decode_lock = threading.Lock()


def _clear_mlx_cache() -> None:
    try:
        import mlx.core as mx

        _mlx_cache_limit()
        mx.clear_cache()
    except Exception:
        pass


def _mlx_cache_limit() -> None:
    raw = os.environ.get("PARROT_PHONON_MLX_CACHE_LIMIT_MB", "256").strip()
    if not raw or raw == "0":
        return
    try:
        import mlx.core as mx

        mx.set_cache_limit(int(raw) * 1024 * 1024)
    except Exception:
        pass


def _decodes_idle() -> bool:
    with _decode_lock:
        return _active_decodes == 0


def _decode_enter() -> None:
    global _active_decodes
    with _decode_lock:
        _active_decodes += 1


def _decode_leave() -> None:
    global _active_decodes
    with _decode_lock:
        _active_decodes = max(0, _active_decodes - 1)


def _start_idle_sweeper() -> None:
    global _SWEEPER_STARTED
    if _SWEEPER_STARTED:
        return
    raw = os.environ.get("PARROT_PHONON_IDLE_SWEEP_SEC", "45").strip()
    if not raw or raw == "0":
        return
    try:
        interval = max(5.0, float(raw))
    except ValueError:
        interval = 45.0

    def _loop() -> None:
        while True:
            time.sleep(interval)
            if _decodes_idle():
                _clear_mlx_cache()

    threading.Thread(target=_loop, name="parrot-mlx-idle-sweep", daemon=True).start()
    _SWEEPER_STARTED = True


def _patch_speech_transcribe() -> None:
    global _SPEECH_PATCHED
    if _SPEECH_PATCHED:
        return
    try:
        from fermion._speech.engine import SpeechModel
    except Exception:
        return
    orig = SpeechModel.transcribe_array_detailed
    if getattr(orig, "__parrot_phonon_boot__", False):
        _SPEECH_PATCHED = True
        return

    def transcribe_array_detailed(self, *args, **kwargs):
        _decode_enter()
        try:
            return orig(self, *args, **kwargs)
        finally:
            _decode_leave()
            _clear_mlx_cache()

    transcribe_array_detailed.__parrot_phonon_boot__ = True
    SpeechModel.transcribe_array_detailed = transcribe_array_detailed
    _SPEECH_PATCHED = True


def _patch_phonon2_decode() -> None:
    global _PHONON2_PATCHED
    if _PHONON2_PATCHED:
        return
    try:
        from fermion._speech.engine_phonon2 import Phonon2SpeechModel
    except Exception:
        return
    orig = Phonon2SpeechModel._decode_single
    if getattr(orig, "__parrot_phonon_boot__", False):
        _PHONON2_PATCHED = True
        return

    def _decode_single(self, audio, repetition_penalty):
        try:
            return orig(self, audio, repetition_penalty)
        finally:
            _clear_mlx_cache()

    _decode_single.__parrot_phonon_boot__ = True
    Phonon2SpeechModel._decode_single = _decode_single
    _PHONON2_PATCHED = True


def _on_model_loaded() -> None:
    _mlx_cache_limit()
    _patch_speech_transcribe()
    _patch_phonon2_decode()
    _start_idle_sweeper()


def _patch_backends_load() -> None:
    global _BACKENDS_PATCHED
    if _BACKENDS_PATCHED:
        return
    try:
        from fermion._speech import backends
    except Exception:
        return
    orig = backends.load
    if getattr(orig, "__parrot_phonon_boot__", False):
        _BACKENDS_PATCHED = True
        return

    def load(engine_kind, model_dir, **kw):
        model = orig(engine_kind, model_dir, **kw)
        _on_model_loaded()
        return model

    load.__parrot_phonon_boot__ = True
    backends.load = load
    _BACKENDS_PATCHED = True


_patch_backends_load()
