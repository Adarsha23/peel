# One-off generator: python3 Support/make-chime.py
# Synthesizes the Peel reminder chime — two soft bell strikes (A5 then E6)
# with inharmonic tubular-bell partials, ~1.4s, peak ~-6 dBFS.
import math
import struct
import wave

SR = 44100
DURATION = 1.4
PARTIALS = ((1.0, 1.00, 1.00), (2.76, 0.35, 0.35), (5.40, 0.12, 0.18))


def strike(t, freq, amp, tau):
    if t < 0:
        return 0.0
    attack = min(1.0, t / 0.003)
    s = 0.0
    for ratio, pamp, ptau in PARTIALS:
        s += pamp * math.sin(2 * math.pi * freq * ratio * t) * math.exp(-t / (tau * ptau))
    return amp * attack * s


samples = []
for i in range(int(SR * DURATION)):
    t = i / SR
    v = strike(t, 880.00, 0.55, 0.50)          # A5
    v += strike(t - 0.17, 1318.51, 0.40, 0.45)  # E6, 170ms later
    samples.append(v)

peak = max(abs(s) for s in samples)
scale = 0.5 / peak
with wave.open("Support/peel-chime.wav", "w") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(b"".join(struct.pack("<h", int(s * scale * 32767)) for s in samples))
print("wrote Support/peel-chime.wav")
