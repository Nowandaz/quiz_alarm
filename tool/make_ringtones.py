"""Generates the preset alarm ringtones in assets/sounds/ringtones/.

The tones are synthesised (no samples), so they are free to ship.
Needs numpy and ffmpeg:  python tool/make_ringtones.py
Each file is a few seconds long and is looped by the alarm.
"""
import os
import subprocess
import tempfile
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sounds", "ringtones")


def tone(freq, dur, harmonics=(1.0,), attack=0.005, release=0.02):
    t = np.arange(int(SR * dur)) / SR
    y = sum(a * np.sin(2 * np.pi * freq * (i + 1) * t) for i, a in enumerate(harmonics))
    env = np.minimum(1, t / attack) * np.minimum(1, (dur - t) / release)
    return y * env / sum(harmonics)


def bell(freq, dur, partials=((1, 1.0), (2.0, 0.5), (3.0, 0.25)), decay=3.0):
    t = np.arange(int(SR * dur)) / SR
    y = sum(a * np.sin(2 * np.pi * freq * m * t) * np.exp(-decay * m * t) for m, a in partials)
    return y * np.minimum(1, t / 0.003) / sum(a for _, a in partials)


def silence(dur):
    return np.zeros(int(SR * dur))


def classic_beep():
    beep = tone(1000, 0.09, (1, 0.3))
    group = np.concatenate([np.concatenate([beep, silence(0.07)]) for _ in range(4)])
    return np.concatenate([np.concatenate([group, silence(0.45)]) for _ in range(4)])


def digital():
    a, b = tone(880, 0.12, (1, 0.5, 0.25)), tone(1320, 0.12, (1, 0.5, 0.25))
    bar = np.concatenate([a, b, a, b, a, b, silence(0.35)])
    return np.concatenate([bar] * 4)


def gentle_chime():
    notes = [523.25, 659.25, 783.99, 1046.5, 783.99, 659.25]
    y = np.zeros(int(SR * 5.2))
    for i, f in enumerate(notes):
        b = bell(f, 2.2, decay=1.6)
        start = int(SR * 0.75 * i)
        y[start:start + len(b)] += b[: len(y) - start]
    return y


def rising():
    steps = [392, 440, 494, 523, 587, 659, 740, 784]
    parts = []
    for i, f in enumerate(steps):
        parts += [tone(f, 0.32, (1, 0.4, 0.15), attack=0.03, release=0.08) * (0.35 + 0.65 * i / 7), silence(0.08)]
    return np.concatenate(parts + [silence(0.5)])


def siren():
    dur = 6.0
    t = np.arange(int(SR * dur)) / SR
    freq = 800 + 350 * np.sin(2 * np.pi * 0.75 * t)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    y = np.sin(phase) + 0.3 * np.sin(2 * phase)
    return y / 1.3


def bell_tower():
    strike = bell(220, 2.4, ((1, 1.0), (2.0, 0.6), (2.4, 0.5), (3.0, 0.3), (4.2, 0.2)), decay=0.9)
    y = np.zeros(int(SR * 6.0))
    for i in range(3):
        start = int(SR * 1.8 * i)
        y[start:start + len(strike)] += strike[: len(y) - start]
    return y


# ------------------------------------------------------------------ musical
# Fuller sounds: struck and plucked instruments, a little room echo, and
# real melodies, so waking up is not only beeps.

def note(name):
    """'C4', 'F#5', 'Bb3' -> frequency in Hz."""
    steps = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    n = steps[name[0]] + name.count("#") - name.count("b")
    return 440.0 * 2 ** ((n + 12 * (int(name[-1]) - 4)) / 12)


def struck(freq, dur, partials, decay, attack=0.002):
    """A struck or plucked note: each partial (ratio, level, extra decay)
    dies away at its own speed, the high ones fastest."""
    t = np.arange(int(SR * dur)) / SR
    y = sum(a * np.sin(2 * np.pi * freq * m * t) * np.exp(-(decay + d) * t) for m, a, d in partials)
    return y * np.minimum(1, t / attack)


def marimba(freq, dur=1.2):
    return struck(freq, dur, ((1, 1.0, 0), (4.0, 0.28, 14), (10.0, 0.08, 30)), decay=5.5)


def music_box(freq, dur=2.2):
    return struck(freq, dur, ((1, 1.0, 0), (2.0, 0.35, 2), (3.0, 0.12, 5), (5.4, 0.08, 9)), decay=2.6)


def kalimba(freq, dur=1.6):
    return struck(freq, dur, ((1, 1.0, 0), (2.0, 0.18, 6), (5.6, 0.22, 22), (6.3, 0.1, 26)), decay=3.6)


def piano(freq, dur=2.4):
    # Slightly stretched harmonics, as real strings have.
    parts = tuple((k * (1 + 0.0004 * k * k), 1.0 / k ** 1.25, 0.9 * k) for k in range(1, 9))
    return struck(freq, dur, parts, decay=1.5, attack=0.004)


def place(track, sound, at, level=1.0):
    start = int(SR * at)
    end = min(len(track), start + len(sound))
    if end > start:
        track[start:end] += level * sound[: end - start]


def room(y, delays=(0.031, 0.047, 0.071), feedback=0.28, mix=0.22):
    """A small room: a few short echoes fed back on themselves."""
    wet = np.zeros(len(y))
    for d in delays:
        n = int(SR * d)
        echo = np.zeros(len(y))
        echo[n:] = y[:-n]
        for _ in range(4):
            again = np.zeros(len(y))
            again[n:] = echo[:-n] * feedback
            echo += again
        wet += echo / len(delays)
    return y + mix * wet


def fade_ends(y, seconds=0.03):
    n = int(SR * seconds)
    y[:n] *= np.linspace(0, 1, n)
    y[-n:] *= np.linspace(1, 0, n)
    return y


def lowpass(y, strength):
    """One-pole low-pass; strength 0..1 (higher = darker)."""
    out = np.empty(len(y))
    acc = 0.0
    a = 1.0 - strength
    for i, v in enumerate(y):
        acc += a * (v - acc)
        out[i] = acc
    return out


def morning_marimba():
    beat = 0.26
    tune = ["E5", "G5", "A5", "B5", "A5", "G5", "E5", "D5",
            "E5", "G5", "B5", "D6", "B5", "A5", "G5", None,
            "A5", "B5", "D6", "E6", "D6", "B5", "A5", "G5",
            "E5", "G5", "A5", "G5", "E5", "D5", "E5", None]
    bass = ["E3", None, None, None, "C3", None, None, None, "G3", None, None, None, "D3", None, None, None] * 2
    y = np.zeros(int(SR * (beat * len(tune) + 0.9)))
    for i, n in enumerate(tune):
        if n:
            place(y, marimba(note(n)), beat * i, 0.9)
    for i, n in enumerate(bass):
        if n:
            place(y, marimba(note(n), 1.8), beat * i, 0.7)
    return fade_ends(room(y))


def music_box_tune():
    beat = 0.34
    tune = ["G5", "B5", "D6", "B5", "C6", "E6", "G6", "E6",
            "D6", "B5", "G5", "B5", "A5", "C6", "F#6", None,
            "G5", "B5", "D6", "G6", "F#6", "D6", "B5", "D6",
            "C6", "A5", "F#5", "A5", "G5", None, None, None]
    y = np.zeros(int(SR * (beat * len(tune) + 1.2)))
    for i, n in enumerate(tune):
        if n:
            place(y, music_box(note(n)), beat * i, 0.85)
            if i % 4 == 0:  # a soft note an octave down on each bar
                place(y, music_box(note(n) / 2, 3.0), beat * i, 0.4)
    return fade_ends(room(y, mix=0.3))


def kalimba_sunrise():
    beat = 0.22
    bars = [["C4", "G4", "C5", "E5", "G5", "E5", "C5", "G4"],
            ["A3", "E4", "A4", "C5", "E5", "C5", "A4", "E4"],
            ["F3", "C4", "F4", "A4", "C5", "A4", "F4", "C4"],
            ["G3", "D4", "G4", "B4", "D5", "B4", "G4", "D4"]]
    notes = [n for bar in bars for n in bar] * 2
    y = np.zeros(int(SR * (beat * len(notes) + 1.0)))
    for i, n in enumerate(notes):
        # Grows from soft to full over the loop, like light coming up.
        place(y, kalimba(note(n) * 2), beat * i, 0.45 + 0.55 * i / len(notes))
    return fade_ends(room(y, mix=0.26))


def piano_dawn():
    chords = [["C4", "E4", "G4", "C5"], ["A3", "C4", "E4", "A4"], ["F3", "A3", "C4", "F4"], ["G3", "B3", "D4", "G4"]]
    top = ["E5", "G5", "C6", "G5", "C5", "E5", "A5", "E5", "A4", "C5", "F5", "C5", "B4", "D5", "G5", "D5"]
    bar = 1.6
    y = np.zeros(int(SR * (bar * len(chords) + 1.6)))
    for b, chord in enumerate(chords):
        for k, n in enumerate(chord):
            place(y, piano(note(n), 3.0), bar * b + 0.018 * k, 0.5)
        for k in range(4):
            place(y, piano(note(top[b * 4 + k]), 1.8), bar * b + 0.4 * k, 0.75)
    return fade_ends(room(y, delays=(0.043, 0.067, 0.097), mix=0.3))


def sunrise_swell():
    # A warm chord that opens up, with small bells over it.
    dur = 10.0
    t = np.arange(int(SR * dur)) / SR
    pad = np.zeros(len(t))
    for n in ("C3", "G3", "E4", "B4", "D5"):
        f = note(n)
        for detune in (-0.35, 0.0, 0.35):
            pad += np.sin(2 * np.pi * (f + detune) * t) + 0.35 * np.sin(2 * np.pi * 2 * (f + detune) * t)
    swell = 0.25 + 0.75 * np.sin(np.pi * t / dur) ** 1.5
    y = 0.05 * pad * swell
    for i, n in enumerate(["G5", "B5", "D6", "E6", "D6", "B5", "E6", "G6", "E6", "D6"]):
        place(y, music_box(note(n), 2.6), 0.6 + 0.9 * i, 0.3 + 0.03 * i)
    return fade_ends(room(y, mix=0.3), 0.25)


def upbeat():
    # For heavy sleepers: a bright riff over a kick and a tick.
    beat = 0.19
    riff = ["E5", "E5", "G5", "E5", "A5", "E5", "B5", "A5", "E5", "E5", "G5", "E5", "D6", "B5", "A5", "G5"] * 2
    y = np.zeros(int(SR * (beat * len(riff) + 0.4)))
    for i, n in enumerate(riff):
        f = note(n)
        t = np.arange(int(SR * 0.17)) / SR
        pluck = (np.sin(2 * np.pi * f * t) + 0.5 * np.sin(2 * np.pi * 2 * f * t) + 0.25 * np.sin(2 * np.pi * 3 * f * t))
        place(y, pluck * np.exp(-9 * t) * np.minimum(1, t / 0.003), beat * i, 0.55)
        if i % 4 == 0:  # kick drum: a sine that drops in pitch
            k = np.arange(int(SR * 0.22)) / SR
            place(y, np.sin(2 * np.pi * (48 * k + 70 * (1 - np.exp(-28 * k)) / 28 * 28)) * np.exp(-11 * k), beat * i, 0.9)
        if i % 2 == 1:  # tick
            h = np.arange(int(SR * 0.04)) / SR
            noise = np.random.default_rng(i).standard_normal(len(h))
            place(y, noise * np.exp(-90 * h), beat * i, 0.12)
        if i % 8 == 0:
            place(y, marimba(note("E3"), 1.0), beat * i, 0.6)
    return fade_ends(room(y, mix=0.12))


LOUDER = {"morning_marimba", "music_box", "kalimba_sunrise", "piano_dawn", "sunrise_swell", "upbeat"}

PRESETS = {
    "morning_marimba": morning_marimba,
    "music_box": music_box_tune,
    "kalimba_sunrise": kalimba_sunrise,
    "piano_dawn": piano_dawn,
    "sunrise_swell": sunrise_swell,
    "upbeat": upbeat,
    "classic_beep": classic_beep,
    "digital": digital,
    "gentle_chime": gentle_chime,
    "rising": rising,
    "siren": siren,
    "bell_tower": bell_tower,
}

os.makedirs(OUT, exist_ok=True)
for name, make in PRESETS.items():
    y = make()
    y = y / np.max(np.abs(y))
    if name in LOUDER:
        # Struck notes are mostly quiet between their peaks. Press the
        # peaks down gently so the whole tune is loud enough to wake to.
        y = np.tanh(2.6 * y) / np.tanh(2.6)
    y = 0.89 * y / np.max(np.abs(y))
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        with wave.open(tmp, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes((y * 32767).astype("<i2").tobytes())
    dest = os.path.join(OUT, f"{name}.mp3")
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name, "-codec:a", "libmp3lame", "-b:a", "128k" if name in LOUDER else "96k", dest],
        check=True,
    )
    os.unlink(tmp.name)
    print(f"{name}.mp3  {len(y) / SR:.1f}s  {os.path.getsize(dest) // 1024} KB")
