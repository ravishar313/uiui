"""CPU unit tests for code/train/augment.py and its wiring in data.Collator (no GPU, no HF model: a fake extractor/tokenizer is injected).
    CUDA_VISIBLE_DEVICES= python3 -m unittest test_augment -v      (any box with numpy/scipy/soundfile/torch)"""
import json, random, sys, tempfile, unittest
from pathlib import Path
import numpy as np
import soundfile as sf
import torch

TRAIN = Path(__file__).resolve().parent.parent.parent / "train"
sys.path.insert(0, str(TRAIN))
import augment as A  # noqa: E402
import data as D  # noqa: E402

SR = 16000
P = lambda x: float(np.mean(np.square(x, dtype=np.float64)))


def speechlike(n, seed):
    r = np.random.default_rng(seed); t = np.arange(n) / SR
    return (0.1 * r.standard_normal(n) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))).astype(np.float32)


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); d = Path(cls.tmp.name); cls.d = d
        r = np.random.default_rng(0)
        def lst(name, files):
            (d / name).write_text("".join(json.dumps({"path": str(p), "seconds": n / SR}) + "\n" for p, n in files))
            return str(d / name)
        noise = []
        for i, n in enumerate([SR * 2, SR * 30, SR * 7]):      # short (looped), long (random offset), medium
            p = d / f"n{i}.wav"; sf.write(p, (0.05 * r.standard_normal(n)).astype(np.float32), SR, subtype="FLOAT"); noise.append((p, n))
        bab = []
        for i in range(6):
            p = d / f"b{i}.wav"; sf.write(p, speechlike(SR * 12, 100 + i), SR, subtype="FLOAT"); bab.append((p, SR * 12))
        rirs = []
        h = np.zeros(4000, np.float32); h[200] = 1.0; h[900:] += 0.3 * r.standard_normal(3100).astype(np.float32) * np.exp(-np.arange(3100) / 800).astype(np.float32)
        p = d / "r0.wav"; sf.write(p, h, SR, subtype="FLOAT"); rirs.append((p, len(h)))
        p = d / "rdelta.wav"; sf.write(p, np.array([0, 0, 1.0, 0], np.float32), SR, subtype="FLOAT"); rirs.append((p, 4))
        cls.noise_list, cls.babble_list, cls.rir_list = lst("noise.jsonl", noise), lst("babble.jsonl", bab), lst("rir.jsonl", rirs)
        cls.rir_only_delta = lst("rd.jsonl", rirs[1:])

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def cfg(self, **kw):
        c = {"prob": 1.0, "seed": 3, "noise_list": self.noise_list, "babble_list": self.babble_list, "rir_list": self.rir_list}; c.update(kw); return c


class TestAugment(Base):
    def test_snr_noise(self):
        w = speechlike(SR * 5, 1)
        for lo, hi in [(10, 10), (-3, -3), (25, 25)]:
            a = A.Augmenter(self.cfg(noise={"prob": 1, "snr_db": [lo, hi], "babble_prob": 0}))
            for k in range(8):
                o = a(w, (1, k)); self.assertEqual(len(o), len(w))
                self.assertAlmostEqual(10 * np.log10(P(w) / P(o - w)), lo, delta=0.05)   # clip-free: amplitudes small

    def test_snr_babble_and_range(self):
        w = speechlike(SR * 4, 2)
        a = A.Augmenter(self.cfg(noise={"prob": 1, "snr_db": [5, 25], "babble_prob": 1.0}))
        snrs = [10 * np.log10(P(w) / P(a(w, (2, k)) - w)) for k in range(40)]
        self.assertTrue(all(5 - 0.05 <= s <= 25 + 0.05 for s in snrs)); self.assertGreater(max(snrs) - min(snrs), 8)  # spreads over the range

    def test_noise_short_and_long_files(self):
        w = speechlike(SR * 9, 3)                       # longer than the 2 s and 7 s noise files -> looping; 30 s file -> offset
        a = A.Augmenter(self.cfg(noise={"prob": 1, "snr_db": [10, 10], "babble_prob": 0}))
        for k in range(30):
            o = a(w, (3, k)); self.assertEqual(o.shape, w.shape); self.assertEqual(o.dtype, np.float32)

    def test_rir_level_length_and_delay(self):
        w = speechlike(SR * 3, 4)
        a = A.Augmenter(self.cfg(rir={"prob": 1}, **{}))
        a.rir_p = 1; a._lists["rir"] = [(str(self.d / "r0.wav"), 0.25)]
        o = a(w, (4, 0)); self.assertEqual(len(o), len(w)); self.assertAlmostEqual(P(o) / P(w), 1.0, delta=1e-3)
        self.assertFalse(np.allclose(o, w))
        a._lists["rir"] = [(str(self.d / "rdelta.wav"), 0.0)]   # delta at index 2 -> identity after direct-path alignment
        np.testing.assert_allclose(a(w, (4, 1)), w, atol=1e-5)

    def test_speed_length_and_cap(self):
        w = speechlike(SR * 6, 5)
        for f in (0.9, 1.1):
            a = A.Augmenter(self.cfg(speed={"prob": 1, "factors": [f]}), max_secs=15)
            o = a(w, (5, 0)); self.assertLessEqual(abs(len(o) - len(w) / f), 1)
        a = A.Augmenter(self.cfg(speed={"prob": 1, "factors": [0.9]}), max_secs=6.5)   # 6/0.9 = 6.67 > cap -> not applied
        self.assertEqual(len(a(w, (5, 1))), len(w))
        a = A.Augmenter(self.cfg(speed={"prob": 1, "factors": [0.9, 1.1]}), max_secs=6.5)   # only 1.1 allowed
        for k in range(10): self.assertLessEqual(len(a(w, (5, k))), 6.5 * SR)
        # a 1 kHz tone moves to 1/f: pitch changes with tempo (resampling)
        t = np.sin(2 * np.pi * 1000 * np.arange(SR) / SR).astype(np.float32)
        o = A.Augmenter(self.cfg(speed={"prob": 1, "factors": [1.1]}))(t, (0, 0))
        f0 = np.argmax(np.abs(np.fft.rfft(o))) * SR / len(o); self.assertAlmostEqual(f0, 1100, delta=15)

    def test_gain_and_clip(self):
        w = speechlike(SR * 2, 6)
        o = A.Augmenter(self.cfg(gain_db=[6, 6]))(w, (6, 0)); self.assertAlmostEqual(P(o) / P(w), 10 ** 0.6, delta=0.01)
        loud = np.full(SR, 0.9, np.float32)
        o = A.Augmenter(self.cfg(gain_db=[6, 6]))(loud, (6, 1)); self.assertLessEqual(float(np.abs(o).max()), 1.0)
        self.assertEqual(float(o.max()), 1.0)

    def test_gate_prob_and_determinism(self):
        w = speechlike(SR * 3, 7)
        full = dict(noise={"prob": 0.6, "snr_db": [5, 25], "babble_prob": 0.3}, rir={"prob": 0.3}, speed={"prob": 0.3, "factors": [0.9, 1.1]}, gain_db=[-6, 6])
        a, b = A.Augmenter(self.cfg(**full)), A.Augmenter(self.cfg(**full))
        for k in range(20): np.testing.assert_array_equal(a(w, (9, k)), b(w, (9, k)))      # same (seed, key) => identical, across instances
        self.assertFalse(np.array_equal(a(w, (9, 1)), a(w, (9, 2))))
        a0 = A.Augmenter(self.cfg(prob=0.0, **full))
        self.assertIs(a0(w, (1, 1)), w)
        a5 = A.Augmenter(self.cfg(prob=0.5, **full)); same = sum(a5(w, (11, k)) is w for k in range(400))
        self.assertTrue(140 < same < 260, same)

    def test_config_validation(self):
        self.assertFalse(A.enabled(None)); self.assertFalse(A.enabled({})); self.assertFalse(A.enabled({"prob": 0})); self.assertFalse(A.enabled({"enabled": False, "prob": 1}))
        self.assertTrue(A.enabled({"prob": 0.5}))
        with self.assertRaises(ValueError): A.Augmenter({"prob": 1, "noise": {"prob": 1}})                 # no noise_list
        with self.assertRaises(ValueError): A.Augmenter({"prob": 1, "rir": {"prob": 1}})                   # no rir_list
        with self.assertRaises(ValueError): A.Augmenter({"prob": 1, "noise": {"prob": 1, "snr_db": [9, 3]}, "noise_list": self.noise_list})
        A.Augmenter({"prob": 1, "gain_db": [-6, 6]})                                                       # stages without lists are fine


class FakeFE:
    """Stand-in for the HF mel extractor: 10 ms frames of log-energy, zero padded to the longest clip."""
    def __call__(self, waves, sampling_rate, return_tensors, padding, return_attention_mask):
        fr = [np.log(np.square(w[: len(w) // 160 * 160]).reshape(-1, 160).mean(1) + 1e-8) for w in waves]
        T = max(len(f) for f in fr); x = torch.zeros(len(fr), T, 80); m = torch.zeros(len(fr), T, dtype=torch.long)
        for i, f in enumerate(fr): x[i, : len(f), :] = torch.tensor(f, dtype=torch.float32)[:, None]; m[i, : len(f)] = 1
        return {"input_features": x, "attention_mask": m}


class FakeTok:
    def encode(self, t, add_special_tokens=False): return [ord(c) % 50 for c in t]


class TestWiring(Base):
    def setUp(self):
        r = np.random.default_rng(1); self.items = []
        for i in range(6):
            p = self.d / f"clip{i}.wav"; w = speechlike(int(SR * (2 + i * 0.5)), 20 + i); sf.write(p, w, SR, subtype="FLOAT")
            self.items.append({"id": str(i), "audio": str(p), "text": f"hello {i}", "dur": len(w) / SR})

    def run_col(self, **kw):
        c = D.Collator("unused", {"enabled": True, "freq_width": 6, "time_masks": 3, "time_width": 0.03}, self.items, **kw); c._fe, c._tok = FakeFE(), FakeTok()
        random.seed(5); return c([0, 1, 2, 3])

    def test_off_parity(self):
        ref = self.run_col()
        for aug in (None, {}, {"prob": 0}, {"enabled": False, "prob": 1, "noise": {"prob": 1}}):
            out = self.run_col(augment=aug, max_secs=15)
            self.assertIsNone(D.Collator("u", None, self.items, augment=aug).aug)
            self.assertTrue(torch.equal(out["feats"], ref["feats"]) and torch.equal(out["mask"], ref["mask"]) and out["ids"] == ref["ids"], aug)

    def test_on_changes_features_keeps_labels_and_specaug_stream(self):
        ref = self.run_col()
        out = self.run_col(augment=self.cfg(prob=1.0, noise={"prob": 1, "snr_db": [5, 5], "babble_prob": 0.3}, gain_db=[-6, 6]), max_secs=15)
        self.assertFalse(torch.equal(out["feats"], ref["feats"])); self.assertEqual(out["ids"], ref["ids"]); self.assertEqual(out["idxs"], ref["idxs"])
        # augmentation must not consume the global RNG that SpecAugment uses: the zeroed positions are identical
        self.assertTrue(torch.equal(out["feats"] == 0, ref["feats"] == 0))
        again = self.run_col(augment=self.cfg(prob=1.0, noise={"prob": 1, "snr_db": [5, 5], "babble_prob": 0.3}, gain_db=[-6, 6]), max_secs=15)
        self.assertTrue(torch.equal(out["feats"], again["feats"]))   # deterministic for the same batch

    def test_speed_changes_batch_length_only(self):
        ref = self.run_col()
        out = self.run_col(augment=self.cfg(prob=1.0, speed={"prob": 1, "factors": [0.9]}), max_secs=15)
        self.assertGreater(out["feats"].shape[1], ref["feats"].shape[1]); self.assertEqual(out["secs"], ref["secs"])

    def test_eval_path_untouched(self):
        src = (TRAIN / "evaluate.py").read_text()
        self.assertNotIn("augment", src); self.assertNotIn("Collator", src)           # eval reads raw audio via read_wave only
        self.assertEqual(D.read_wave(self.items[0]["audio"]).dtype, np.float32)      # read_wave itself has no augmentation hook


if __name__ == "__main__": unittest.main()
