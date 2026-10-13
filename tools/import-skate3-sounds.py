"""Import Skate 3's own board sounds from your PS3 copy of Skate 3.

Usage: python tools/import-skate3-sounds.py "<Skate 3>/PS3_GAME/USRDIR/data/audio"

Reads the *.big ("EB") archives, decodes the EALayer3 streams with vgmstream
(put vgmstream-cli.exe in tools/vgmstream), picks clips by acoustic features
and writes Ogg Vorbis clips (via ffmpeg) to mod/sm64-skate/sound, which is
where the mod loads them from. Loop clips (roll, grind) get a 120 ms crossfade.
No game audio is included in this repository.
"""
import glob, json, os, shutil, struct, subprocess, sys
import numpy as np

GAME = sys.argv[1] if len(sys.argv) > 1 else ""
HERE = os.path.dirname(os.path.abspath(__file__))
VGM = os.path.join(HERE, "vgmstream", "vgmstream-cli.exe")
WORK = os.path.join(HERE, ".work", "skate3-audio")
OUT = os.path.join(WORK, "wav")
MOD_SOUND = os.path.join(HERE, "..", "mod", "sm64-skate", "sound")

def eb(path):
    d = open(path, "rb").read()
    assert d[:2] == b"EB", path
    n = struct.unpack_from(">I", d, 4)[0]
    names_off = struct.unpack_from(">I", d, 0xC)[0]
    names = [p.decode("latin1") for p in d[names_off:names_off + n * 256].split(b"\0") if len(p) > 3][:n]
    shift = d[0x0A]  # entry offsets are in (1 << shift)-byte units
    entries = [(struct.unpack_from(">I", d, 0x30 + 16 * k)[0] << shift, struct.unpack_from(">I", d, 0x38 + 16 * k)[0]) for k in range(n)]
    return d, dict(zip(names, entries))

def decode(src, dst, subsong=None):
    cmd = [VGM, "-i", "-o", dst] + (["-s", str(subsong)] if subsong else []) + [src]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def load(f):
    d = open(f, "rb").read(); i = d.find(b"fmt "); ch, rate = struct.unpack_from("<HI", d, i + 10); j = d.find(b"data")
    a = np.frombuffer(d[j + 8:], dtype="<i2").astype(np.float32) / 32768
    if ch == 2: a = a[: len(a) // 2 * 2].reshape(-1, 2).mean(1)
    return a, rate

def save(path, a, rate):
    a = np.clip(a, -1, 1); pcm = (a * 32767).astype("<i2").tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm)

def loopable(a, rate, fade=0.12):
    n = int(rate * fade)
    body, tail = a[:-n].copy(), a[-n:]
    t = np.linspace(0, 1, n, dtype=np.float32)
    body[:n] = body[:n] * np.sqrt(t) + tail * np.sqrt(1 - t)
    return body

def trim(a, rate, seconds):
    a = a[: int(rate * seconds)]
    fade = min(len(a) // 4, int(rate * 0.03))
    a[-fade:] *= np.linspace(1, 0, fade, dtype=np.float32)
    return a

def main():
    if not os.path.isfile(os.path.join(GAME, "audiofiles.big")):
        sys.exit("Pass the Skate 3 data/audio folder (it contains audiofiles.big and grains.big).")
    if not os.path.isfile(VGM):
        sys.exit("vgmstream-cli.exe not found in tools/vgmstream (download it from vgmstream.org).")
    os.makedirs(WORK, exist_ok=True); os.makedirs(OUT, exist_ok=True)
    for f in glob.glob(os.path.join(OUT, "board_*.wav")): os.remove(f)

    # Rolling: Skate 3's asphalt grain (the street) as one long loop.
    d, files = eb(os.path.join(GAME, "grains.big"))
    o, s = files["asphalt_smooth_hard.grain"]; blob = d[o:o + s]
    snr = os.path.join(WORK, "asphalt_smooth_hard.snr"); open(snr, "wb").write(blob[struct.unpack_from(">I", blob, 0)[0]:])
    decode(snr, os.path.join(WORK, "roll.wav"))
    a, r = load(os.path.join(WORK, "roll.wav")); save(os.path.join(OUT, "board_roll.wav"), loopable(a / max(1e-6, np.abs(a).max()) * 0.9, r), r)

    # Banks from audiofiles.big.
    d, files = eb(os.path.join(GAME, "audiofiles.big"))
    for bank in ("GRINDS.abk", "Bodyslide.abk", "fstep_skateshoe1_sm.abk", "Skate_Collisions.bnk"):
        o, s = files[bank]; open(os.path.join(WORK, bank), "wb").write(d[o:o + s])

    # Grind: steady, bright metal grind loops.
    picks = {"board_grind": [69, 57]}
    for k, idx in enumerate(picks["board_grind"]):
        out = os.path.join(WORK, f"grind{idx}.wav"); decode(os.path.join(WORK, "GRINDS.abk"), out, idx)
        a, r = load(out); save(os.path.join(OUT, "board_grind" + ("" if k == 0 else f"_{k + 1}") + ".wav"), loopable(a, r), r)

    # Collisions bank (SPLC): raw EALayer3 v2 streams with 8-byte SNR headers.
    c = open(os.path.join(WORK, "Skate_Collisions.bnk"), "rb").read(); start = struct.unpack_from(">I", c, 8)[0]
    heads = [i for i in range(start, len(c) - 8, 2)
             if (struct.unpack_from(">I", c, i)[0] & 0x3FFFF) == 48000 and struct.unpack_from(">I", c, i)[0] >> 18 == 7 << 6
             and 500 < (struct.unpack_from(">I", c, i + 4)[0] & 0x1FFFFFFF) < 48000 * 20]
    feats = []
    cdir = os.path.join(WORK, "coll"); os.makedirs(cdir, exist_ok=True)
    for k, i in enumerate(heads):
        snr = os.path.join(cdir, f"c{k:04d}.snr"); wav = snr[:-4] + ".wav"
        open(snr, "wb").write(c[i:heads[k + 1] if k + 1 < len(heads) else len(c)])
        try: decode(snr, wav)
        except subprocess.CalledProcessError: continue
        a, r = load(wav)
        if len(a) < 256: continue
        env = np.convolve(np.abs(a), np.ones(240) / 240, "same")
        seg = a[: int(r * 0.3)]; sp = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))); fr = np.fft.rfftfreq(len(seg), 1 / r)
        feats.append(dict(f=wav, dur=len(a) / r, peak=float(np.abs(a).max()), rms=float(np.sqrt((a * a).mean())),
                          att=float(np.argmax(env) / r), cen=float((sp * fr).sum() / max(sp.sum(), 1e-9))))
    pops = sorted([x for x in feats if 0.08 <= x["dur"] <= 0.5 and x["att"] < 0.012 and x["peak"] > 0.5 and 1200 < x["cen"] < 5000], key=lambda x: -x["peak"] * x["rms"])[:4]
    lands = sorted([x for x in feats if 0.3 <= x["dur"] <= 1.2 and x["att"] < 0.02 and x["peak"] > 0.6 and x["cen"] < 1600], key=lambda x: -x["rms"])[:4]
    for name, chosen, length in (("board_pop", pops, 0.45), ("board_land", lands, 0.8)):
        for k, x in enumerate(chosen):
            a, r = load(x["f"]); save(os.path.join(OUT, name + ("" if k == 0 else f"_{k + 1}") + ".wav"), trim(a, r, length), r)

    # Bail: body slides. Push: skate-shoe scuffs.
    for name, bank, subs, length in (("board_bail", "Bodyslide.abk", [14, 11], 1.0), ("board_push", "fstep_skateshoe1_sm.abk", [100, 120, 124, 125], 0.35)):
        for k, idx in enumerate(subs):
            out = os.path.join(WORK, f"{name}{idx}.wav"); decode(os.path.join(WORK, bank), out, idx)
            a, r = load(out); save(os.path.join(OUT, name + ("" if k == 0 else f"_{k + 1}") + ".wav"), trim(a, r, length), r)

    json.dump({"pops": pops, "lands": lands}, open(os.path.join(WORK, "picked.json"), "w"), indent=1)
    # coopdx plays .ogg/.mp3/.aiff only.
    os.makedirs(MOD_SOUND, exist_ok=True)
    for f in sorted(glob.glob(os.path.join(OUT, "board_*.wav"))):
        dst = os.path.join(MOD_SOUND, os.path.basename(f)[:-4] + ".ogg")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", f, "-c:a", "libvorbis", "-q:a", "5", dst], check=True)
    print("Wrote:", sorted(os.path.basename(f) for f in glob.glob(os.path.join(MOD_SOUND, "*.ogg"))))

if __name__ == "__main__":
    main()
