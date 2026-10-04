#!/usr/bin/env python3
"""Render the illustrative Product Hunt demo video from the approved fox GIF.

    python3 Brand/ProductHunt/render-video-demo.py --track /path/to/Cyberchill.wav

The music is the owner's own track ("Cyberchill"). Crackle is synthesized on
top of it, and the on-screen trace is drawn from the same samples you hear, so
every glitch on screen is a glitch in the speakers; the line's height is the
music's own loudness. Requires Pillow, NumPy and
ffmpeg. This never launches Fennec or repairs audio.
"""

from __future__ import annotations

import argparse
import math
import os
import subprocess
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps, ImageSequence


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent
OUTPUT = HERE / "fennec-audio-demo.mp4"
PREVIEW = HERE / "fennec-audio-demo-preview.gif"
THUMBNAIL = HERE / "fennec-audio-demo-youtube-thumbnail.png"
FOX_GIF = ROOT / "Fennec/Resources/fennec-run.gif"
ICON = ROOT / "Brand/Fennec-AppIcon-Master.png"
FONT = "/System/Library/Fonts/SFNS.ttf"

W, H, FPS = 1920, 1080, 30
SR = 48000
DURATION = 31.0

# The timeline, in video seconds. Each step gets its own large caption so it
# reads when Product Hunt plays the video as a small thumbnail.
TRACK_START = 51.12          # a downbeat just before the track's fullest section
TITLE_END = 3.4              # opening card: what Fennec is
LISTENING = 4.0              # "Listening for crackling"
CRACKLE_START = 8.0          # the fault begins
CRACKLE_FULL = 9.5           # ...and is at full strength by here
DETECTED = 8.6               # "Crackle detected"; the menu-bar fennec turns red
FOX_START = 12.5             # "Resolving…": the fox enters from the left
SILENCE_START = 17.0         # the sound system restarts while the fox runs
SILENCE_END = 18.5           # clean sound returns as the fox leaves
DONE = 19.0                  # "Donesies", with the app's real notification
BANNER_IN, BANNER_OUT = 19.0, 24.6
END_CARD = 27.0
FADE_OUT = 27.8

# Colours sampled from the master art (Brand/ProductHunt/PROMPTS.md).
SKY = "#2373C3"
TWILIGHT = "#294D70"
DUNE = "#EF792D"
DUNE_SHADOW = "#BD5D26"
DUNE_LIGHT = "#F3924C"
SAND = "#ECB478"
CREAM = "#FDDCAF"
INK = "#2C2927"
GOLD = "#DA963E"
ROCK = "#5E544C"
ROCK_LIT = "#7D7066"
SHRUB = "#4F4A2A"
RED = "#FF3B30"              # macOS systemRed, as MenuBarIcon draws it

MENU_H = 42
TRACE_L, TRACE_R, TRACE_Y = 160, 1760, 450
CAPTION_Y = 165
SCOPE_SECONDS = 0.085


def font(size: int, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def hex_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def ease(u: float) -> float:
    u = min(1.0, max(0.0, u))
    return 1 - (1 - u) ** 3


# ---------------------------------------------------------------- audio

@dataclass
class Audio:
    stereo: np.ndarray       # what you hear, float -1...1
    scope: np.ndarray        # what the trace draws, same timeline
    crackling: np.ndarray    # bool per sample: inside a glitch
    scale: float             # scope units -> pixels


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        if w.getframerate() != SR or w.getsampwidth() != 2:
            raise SystemExit(f"{path}: expected 16-bit {SR} Hz PCM")
        raw = np.frombuffer(w.readframes(w.getnframes()), np.int16)
        data = raw.reshape(-1, w.getnchannels()).astype(np.float64) / 32768
    return data if data.shape[1] == 2 else np.repeat(data, 2, axis=1)


def smooth(x: np.ndarray, width: int) -> np.ndarray:
    kernel = np.ones(width) / width
    return np.convolve(np.convolve(x, kernel, mode="same"), kernel, mode="same")


def moving_mean(x: np.ndarray, width: int) -> np.ndarray:
    c = np.concatenate([[0.0], np.cumsum(x)])
    half = width // 2
    hi = np.minimum(np.arange(len(x)) + half + 1, len(x))
    lo = np.maximum(np.arange(len(x)) - half, 0)
    return (c[hi] - c[lo]) / (hi - lo)


def scope_body(mono: np.ndarray) -> np.ndarray:
    """The calm line: a smooth carrier whose height follows the music.

    A literal low-passed waveform goes flat whenever the bass drops out,
    which would draw silence over music you can plainly hear. So the shape is
    a fixed low tone and the height is the track's own short-term loudness;
    the glitches added later are the exact ones in the audio.
    """
    t = np.arange(len(mono)) / SR
    carrier = (np.sin(2 * np.pi * 55 * t) + 0.35 * np.sin(2 * np.pi * 110 * t + 0.6)
               + 0.2 * np.sin(2 * np.pi * 27.5 * t + 1.1))
    loud = np.sqrt(moving_mean(mono ** 2, int(0.06 * SR)))
    return carrier * loud


def build_audio(track_path: Path) -> Audio:
    track = read_wav(track_path)
    n = int(DURATION * SR)
    t = np.arange(n) / SR

    # The player keeps time through the restart: after the silence the song
    # carries on from where it would have been, as a real music app does.
    source = np.minimum(int(TRACK_START * SR) + np.arange(n), len(track) - 1)
    clean = track[source].copy()
    mono = clean.mean(axis=1)
    scope = scope_body(mono)
    out = clean.copy()
    crackling = np.zeros(n, bool)

    rng = np.random.default_rng(1162)
    local_rms = math.sqrt(float(np.mean(mono[int(3 * SR):int(15 * SR)] ** 2)))
    spike = 0.9 * float(np.percentile(np.abs(scope), 99.5))
    cursor = CRACKLE_START
    while cursor < SILENCE_START - 0.03:
        strength = min(1.0, (cursor - CRACKLE_START) / (CRACKLE_FULL - CRACKLE_START))
        a = int(cursor * SR)
        kind = rng.choice(["dropout", "stutter", "burst", "pop"], p=[0.38, 0.22, 0.3, 0.1])
        if kind == "dropout":            # an underrun: a buffer of nothing
            b = min(n, a + int(rng.integers(480, 2400)))
            out[a:b] = 0
            scope[a:b] = 0
        elif kind == "stutter":          # the last buffer, played again
            size = int(rng.integers(256, 1024))
            reps = int(rng.integers(2, 4))
            b = min(n, a + size * reps)
            chunk_out, chunk_scope = out[a - size:a].copy(), scope[a - size:a].copy()
            for r in range(reps):
                s, e = a + r * size, min(b, a + (r + 1) * size)
                out[s:e] = chunk_out[: e - s]
                scope[s:e] = chunk_scope[: e - s]
        elif kind == "burst":            # broadband hash, the audible crackle
            b = min(n, a + int(rng.integers(360, 1500)))
            k = b - a
            noise = rng.normal(0, 1, (k, 2))
            noise -= np.vstack([smooth(noise[:, 0], 9), smooth(noise[:, 1], 9)]).T
            env = np.sin(np.linspace(0, np.pi, k))[:, None] ** 0.5
            out[a:b] = 2.6 * local_rms * noise * env
            scope[a:b] = np.clip(rng.normal(0, 0.55, k), -1.3, 1.3) * spike * env[:, 0]
        else:                            # a single hard pop
            b = min(n, a + 90)
            sign = 1 if rng.random() < 0.5 else -1
            out[a:b] = sign * 0.35 * np.exp(-np.arange(b - a) / 18)[:, None]
            scope[a:b] = sign * 1.3 * spike * np.exp(-np.arange(b - a) / 40)
        crackling[a:b] = True
        gap = rng.exponential(0.34 - 0.21 * strength) + 0.035
        cursor += gap

    # The restart: exact digital silence, with a short ramp either side so
    # the edit itself does not add a click the story did not ask for.
    s, e = int(SILENCE_START * SR), int(SILENCE_END * SR)
    edge = int(0.012 * SR)
    out[s - edge:s] *= np.linspace(1, 0, edge)[:, None]
    out[s:e] = 0
    scope[s:e] = 0
    ramp = int(0.08 * SR)
    out[e:e + ramp] *= np.linspace(0, 1, ramp)[:, None]
    scope[e:e + ramp] *= np.linspace(0, 1, ramp)

    fade_in = int(0.12 * SR)
    out[:fade_in] *= np.linspace(0, 1, fade_in)[:, None]
    f0 = int(FADE_OUT * SR)
    out[f0:] *= np.linspace(1, 0, n - f0)[:, None] ** 1.5
    scope[f0:] *= np.linspace(1, 0, n - f0) ** 1.5
    # Headroom: the glitches' hard edges overshoot after AAC encoding.
    out = np.clip(out * 0.8, -0.98, 0.98)

    scale = 100 / float(np.percentile(np.abs(scope_body(mono)[: int(15 * SR)]), 99.5))
    return Audio(out, scope, crackling, scale)


def write_wav(audio: Audio, destination: Path) -> None:
    pcm = np.int16(audio.stereo * 32767)
    with wave.open(str(destination), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


# ---------------------------------------------------------------- art

def load_fox() -> tuple[list[Image.Image], list[float], float, float]:
    """The approved run cycle, mirrored and cropped exactly as the app does."""
    crop = (40, 53, 40 + 1087, 53 + 544)   # FoxRunMotion.sourceBounds: x, y, w, h
    # Width chosen so one crossing takes the repair beat, at the gait's own
    # ground speed: about 1021 source px of travel per 1.16 s loop.
    width = 500
    scale = width / (crop[2] - crop[0])
    frames, ends, total = [], [], 0.0
    with Image.open(FOX_GIF) as gif:
        for frame in ImageSequence.Iterator(gif):
            image = frame.convert("RGBA").crop(crop)
            image = ImageOps.mirror(image).resize(
                (width, round(image.height * scale)), Image.Resampling.LANCZOS)
            frames.append(image)
            total += frame.info.get("duration", 80) / 1000
            ends.append(total)
    speed = 1021 * scale / total
    return frames, ends, total, speed


def rounded_icon(size: int) -> Image.Image:
    icon = Image.open(ICON).convert("RGBA")
    mask = Image.new("L", icon.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((3, 3, icon.width - 4, icon.height - 4), radius=118, fill=255)
    icon.putalpha(mask)
    return icon.resize((size, size), Image.Resampling.LANCZOS)


def wallpaper() -> Image.Image:
    """Flat vector desert, drawn at 2x and reduced for clean edges."""
    s = 2
    im = Image.new("RGB", (W * s, H * s), SKY)
    d = ImageDraw.Draw(im)

    def poly(points, fill):
        d.polygon([(x * s, y * s) for x, y in points], fill=fill)

    def crest(px, py, left_y, right_y, left_w, right_w):
        """A dune profile: linear base, smooth asymmetric hump at (px, py)."""
        pts = []
        for x in range(-40, W + 41, 8):
            base = left_y + (right_y - left_y) * (x + 40) / (W + 80)
            sigma = left_w if x < px else right_w
            peak_base = left_y + (right_y - left_y) * (px + 40) / (W + 80)
            pts.append((x, base + (py - peak_base) * math.exp(-((x - px) / sigma) ** 2)))
        return pts

    def dune(px, py, left_y, right_y, left_w, right_w, foot, lit, shade):
        """One dune, lit from the left, its lee side cut by one lazy diagonal."""
        line = crest(px, py, left_y, right_y, left_w, right_w)
        poly(line + [(W + 40, H), (-40, H)], lit)
        lee = [q for q in line if q[0] >= px]
        poly([(px, py)] + lee + [(W + 40, foot[1]), foot], shade)

    # Back to front: the far ridge, the near ridge, then the floor.
    dune(1430, 585, 760, 700, 620, 700, (1960, 770), DUNE, DUNE_SHADOW)
    dune(470, 660, 760, 830, 420, 560, (1300, 905), DUNE, DUNE_SHADOW)
    floor = crest(1050, 880, 905, 900, 700, 700)
    poly(floor + [(W + 40, H), (-40, H)], DUNE_LIGHT)
    poly(crest(700, 990, 1004, 1000, 900, 900) + [(W + 40, H), (-40, H)], SAND)

    def rock(cx, base, w, h, lean=0.0):
        pts = [(cx - w / 2, base), (cx - w * 0.38, base - h * 0.62), (cx - w * 0.08 + lean, base - h),
               (cx + w * 0.3 + lean, base - h * 0.82), (cx + w / 2, base)]
        poly(pts, ROCK)
        poly([(cx - w * 0.08 + lean, base - h), (cx + w * 0.3 + lean, base - h * 0.82),
              (cx + w / 2, base), (cx + w * 0.05, base)], ROCK_LIT)

    def shrub(cx, base, size):
        for k in range(9):
            ang = math.radians(-160 + k * 17.5)
            length = size * (0.6 + 0.4 * math.sin(k * 1.7) ** 2)
            d.line([(cx * s, base * s), ((cx + math.cos(ang) * length) * s,
                    (base + math.sin(ang) * length) * s)], fill=SHRUB, width=4 * s)

    rock(215, 842, 150, 96)
    rock(312, 850, 80, 48, 6)
    shrub(384, 852, 44)
    rock(1640, 846, 170, 108, -8)
    rock(1540, 852, 70, 40)
    shrub(1772, 852, 52)
    shrub(1010, 892, 30)
    return im.resize((W, H), Image.Resampling.LANCZOS)


def fennec_glyph(state: str, size: int) -> Image.Image:
    """MenuBarIcon's 24-unit outline, redrawn at 4x for the video."""
    k = 4 * size / 24
    im = Image.new("RGBA", (4 * size, 4 * size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def p(x, y):  # design space has its origin bottom-left
        return (x * k, (24 - y) * k)

    def bez(p0, c1, c2, p1, steps=18):
        out = []
        for i in range(1, steps + 1):
            u = i / steps
            out.append(tuple((1 - u) ** 3 * a + 3 * (1 - u) ** 2 * u * b + 3 * (1 - u) * u ** 2 * c + u ** 3 * e
                             for a, b, c, e in zip(p0, c1, c2, p1)))
        return out

    def m(pt):
        return (24 - pt[0], pt[1])

    chin, cheek, c1, c2 = (12, 1.6), (4.2, 8.4), (8.4, 1.7), (4.2, 4.2)
    shoulder, s1, s2 = (6.2, 11.6), (4.2, 10.2), (5.2, 11.4)
    tip, inner, notch = (1.8, 22.8), (10.9, 13.6), (12, 10.2)
    pts = [chin] + bez(chin, c1, c2, cheek) + bez(cheek, s1, s2, shoulder)
    pts += [tip, inner, notch, m(inner), m(tip), m(shoulder)]
    pts += bez(m(shoulder), m(s2), m(s1), m(cheek)) + bez(m(cheek), m(c2), m(c1), chin)
    ink = RED if state == "detected" else INK
    d.polygon([p(*q) for q in pts], fill=ink)
    if state == "repairing":
        cx, cy, r = 12 * k, (24 - 8.0) * k, 3.4 * k
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(0, 0, 0, 0))
    if state == "detected":
        cx, cy = 12 * k, (24 - 10.6) * k
        for radius in (4.4, 7.2):
            r = radius * k
            d.arc((cx - r, cy - r, cx + r, cy + r), 360 - 114, 360 - 66, fill=ink, width=round(1.7 * k))
    return im.resize((size, size), Image.Resampling.LANCZOS)


def menu_bar(state: str) -> Image.Image:
    bar = Image.new("RGBA", (W, MENU_H), (246, 241, 234, 214))
    d = ImageDraw.Draw(bar)
    f, fb = font(23), font(23, "Bold")
    x = 26
    for i, item in enumerate(["Music", "File", "Edit", "Song", "View", "Controls", "Window", "Help"]):
        face = fb if i == 0 else f
        d.text((x, MENU_H / 2), item, font=face, fill=INK, anchor="lm")
        x += d.textlength(item, font=face) + 26
    clock = "Sat Oct 4  9:41 AM"
    right = W - 24
    d.text((right, MENU_H / 2), clock, font=f, fill=INK, anchor="rm")
    right -= d.textlength(clock, font=f) + 26
    # A plain battery, then Fennec, the only status item that matters here.
    d.rounded_rectangle((right - 36, 13, right - 4, 28), radius=4, outline=INK, width=2)
    d.rectangle((right - 32, 17, right - 11, 24), fill=INK)
    d.rectangle((right - 2, 18, right, 23), fill=INK)
    right -= 36 + 28
    glyph = fennec_glyph(state, 32)
    bar.alpha_composite(glyph, (int(right - 32), (MENU_H - 32) // 2))
    return bar


def banner(icon: Image.Image) -> Image.Image:
    """A macOS-style notification: the app's real repair title, empty body."""
    w, h, s = 560, 96, 3
    im = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, w * s - 1, h * s - 1), radius=22 * s, fill=(245, 243, 240, 255))
    im = im.resize((w, h), Image.Resampling.LANCZOS)
    im.alpha_composite(icon.resize((60, 60), Image.Resampling.LANCZOS), (18, 18))
    d = ImageDraw.Draw(im)
    d.text((94, 38), "Donesies", font=font(24, "Semibold"), fill=INK, anchor="lm")
    d.text((94, 66), "Fennec", font=font(20), fill="#6B635C", anchor="lm")
    d.text((w - 20, 38), "now", font=font(18), fill="#6B635C", anchor="rm")
    return im


# ---------------------------------------------------------------- frames

class Renderer:
    def __init__(self, audio: Audio) -> None:
        self.audio = audio
        self.base = wallpaper()
        self.fox, self.fox_ends, self.fox_loop, self.fox_speed = load_fox()
        self.icon = rounded_icon(220)
        self.badge = rounded_icon(132)
        self.banner = banner(self.icon)
        self.bars = {s: menu_bar(s) for s in ("listening", "detected", "repairing")}
        self.end = self.end_card()

    def end_card(self) -> Image.Image:
        im = self.base.copy().convert("RGBA")
        im.alpha_composite(self.icon, ((W - 220) // 2, 150))
        d = ImageDraw.Draw(im)
        d.text((W / 2, 470), "Fennec", font=font(124, "Bold"), fill=CREAM, anchor="mm")
        d.text((W / 2, 572), "A quiet watchdog for crackling Mac audio", font=font(46, "Medium"),
               fill=CREAM, anchor="mm")
        d.text((W / 2, 1036), "Free  ·  Open source  ·  macOS", font=font(30, "Semibold"),
               fill=INK, anchor="mm")
        return im.convert("RGB")

    def trace(self, sec: float) -> tuple[Image.Image, tuple[int, int]]:
        a = self.audio
        ss = 3
        top, height = TRACE_Y - 200, 400
        width = TRACE_R - TRACE_L
        strip = Image.new("RGBA", (width * ss, height * ss), (0, 0, 0, 0))
        d = ImageDraw.Draw(strip)
        end = int(sec * SR)
        span = int(SCOPE_SECONDS * SR)
        start = end - span
        # Trigger on a rising zero crossing so a steady tone holds still, the
        # way a scope does; a glitch has no steady edge and so jumps around.
        search = a.scope[max(0, start - span // 2):start]
        crossings = np.where((search[:-1] < 0) & (search[1:] >= 0))[0]
        if len(crossings):
            start = max(0, start - span // 2) + int(crossings[-1])
        # Persistence: a glitch stays on screen for a few frames, as it would
        # on a scope, instead of flashing past between two video frames.
        recent = np.flatnonzero(a.crackling[max(0, end - int(0.15 * SR)):end])
        if len(recent):
            glitch = max(0, end - int(0.15 * SR)) + int(recent[0])
            start = max(0, glitch - int(span * 0.35))
        window = a.scope[max(0, start):max(0, start) + span]
        if len(window) < span:
            window = np.pad(window, (span - len(window), 0))
        broken = bool(a.crackling[max(0, end - span * 3):end].any())
        quiet = SILENCE_START <= sec < SILENCE_END
        faulty = CRACKLE_START + 0.4 <= sec < SILENCE_START
        xs = np.linspace(0, width * ss, 900)
        idx = np.linspace(0, span - 1, 900).astype(int)
        taper = np.sin(np.linspace(0, np.pi, 900)) ** 0.35
        ys = (height / 2 - np.clip(window[idx] * a.scale * taper, -125, 125)) * ss
        colour = DUNE if faulty else CREAM
        if quiet:
            ys[:] = height / 2 * ss
        d.line(list(zip(xs.tolist(), ys.tolist())), fill=colour,
               width=(7 if faulty and broken else 6) * ss, joint="curve")
        return strip.resize((width, height), Image.Resampling.LANCZOS), (TRACE_L, top)

    def caption(self, sec: float) -> tuple[str, float]:
        """The large step caption and its opacity (short linear fades)."""
        steps = [(LISTENING, "Listening for crackling"), (DETECTED, "Crackle detected"),
                 (FOX_START, "Resolving…"), (DONE, "Donesies"), (END_CARD, "")]
        for (t0, text), (t1, _) in zip(steps, steps[1:]):
            if t0 <= sec < t1:
                fade = 0.2
                return text, min(1.0, (sec - t0) / fade, (t1 - sec) / fade)
        return "", 0.0

    def frame(self, sec: float) -> Image.Image:
        if sec < TITLE_END:
            return self.end
        im = self.base.convert("RGBA")
        d = ImageDraw.Draw(im)

        # The step caption: the app icon and what Fennec is doing, large.
        im.alpha_composite(self.badge, (TRACE_L, CAPTION_Y - self.badge.height // 2))
        text, alpha = self.caption(sec)
        if text and alpha > 0:
            layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(layer).text((TRACE_L + self.badge.width + 44, CAPTION_Y), text,
                                       font=font(112, "Bold"), fill=CREAM, anchor="lm")
            if alpha < 1:
                layer.putalpha(layer.getchannel("A").point(lambda v: round(v * alpha)))
            im.alpha_composite(layer)

        # The scope and its rule.
        d.line((TRACE_L, TRACE_Y, TRACE_R, TRACE_Y), fill=TWILIGHT, width=2)
        strip, pos = self.trace(sec)
        im.alpha_composite(strip, pos)
        d = ImageDraw.Draw(im)
        d.text((TRACE_L, 318), "Now playing", font=font(32, "Medium"), fill=CREAM, anchor="ls")
        d.text((W - 26, MENU_H + 30), "Illustrative demo  ·  simulated audio", font=font(20, "Medium"),
               fill=CREAM, anchor="rm")

        # The fox walks along the bottom of the screen, paws on the sand.
        if FOX_START <= sec:
            run = sec - FOX_START
            x = -self.fox[0].width + run * self.fox_speed
            if x < W:
                cycle = run % self.fox_loop
                i = next((j for j, e in enumerate(self.fox_ends) if cycle < e), len(self.fox) - 1)
                sprite = self.fox[i]
                im.paste(sprite, (round(x), H - 18 - sprite.height), sprite)

        if sec < DETECTED:
            state = "listening"
        elif sec < FOX_START:
            state = "detected"
        elif sec < SILENCE_END:
            state = "repairing"
        else:
            state = "listening"
        im.alpha_composite(self.bars[state], (0, 0))

        if BANNER_IN <= sec < BANNER_OUT + 0.4:
            slide = ease((sec - BANNER_IN) / 0.4) if sec < BANNER_OUT else 1 - ease((sec - BANNER_OUT) / 0.4)
            x = round(W + 10 - slide * (self.banner.width + 26))
            if x < W:
                im.paste(self.banner, (x, MENU_H + 14), self.banner)

        out = im.convert("RGB")
        if sec < TITLE_END + 0.6:
            out = Image.blend(self.end, out, ease((sec - TITLE_END) / 0.6))
        if sec >= END_CARD:
            out = Image.blend(out, self.end, ease((sec - END_CARD) / 0.6))
        return out


def encode(audio: Audio, folder: Path) -> None:
    renderer = Renderer(audio)
    wav = folder / "audio.wav"
    write_wav(audio, wav)
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{W}x{H}",
               "-framerate", str(FPS), "-i", "pipe:0", "-i", str(wav),
               "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", str(OUTPUT)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    assert process.stdin is not None
    try:
        for n in range(int(DURATION * FPS)):
            sec = n / FPS
            frame = renderer.frame(sec)
            if abs(sec - 14.6) < 1 / (2 * FPS):
                frame.resize((1280, 720), Image.Resampling.LANCZOS).save(THUMBNAIL)
            process.stdin.write(frame.tobytes())
    finally:
        process.stdin.close()
    if process.wait() != 0:
        raise RuntimeError("ffmpeg failed while encoding video")


def preview(folder: Path) -> None:
    palette = folder / "palette.png"
    clip = ["-ss", "7.6", "-t", "13.0", "-i", str(OUTPUT)]
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *clip, "-vf",
                    "fps=12,scale=960:-1:flags=lanczos,palettegen", str(palette)], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *clip, "-i", str(palette),
                    "-filter_complex", "fps=12,scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse",
                    "-loop", "0", str(PREVIEW)], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--track", type=Path, default=os.environ.get("FENNEC_DEMO_TRACK"),
                        help="16-bit 48 kHz WAV of the music bed (or FENNEC_DEMO_TRACK)")
    parser.add_argument("--still", type=float, action="append", default=[],
                        help="write a PNG of this second instead of encoding (repeatable)")
    args = parser.parse_args()
    if args.track is None:
        parser.error("--track is required")
    audio = build_audio(Path(args.track))
    if args.still:
        renderer = Renderer(audio)
        for sec in args.still:
            path = Path(tempfile.gettempdir()) / f"fennec-demo-{sec:05.2f}.png"
            renderer.frame(sec).save(path)
            print(path)
        return
    with tempfile.TemporaryDirectory(prefix="fennec-demo-") as folder:
        encode(audio, Path(folder))
        preview(Path(folder))
    for path in (OUTPUT, PREVIEW, THUMBNAIL):
        print(path)


if __name__ == "__main__":
    main()
