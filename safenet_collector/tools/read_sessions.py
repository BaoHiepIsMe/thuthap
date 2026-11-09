#!/usr/bin/env python3
"""Đọc dữ liệu SafeNet Collector, in thống kê và cắt cửa sổ 151 mẫu @ 50 Hz.

Chỉ dùng numpy + pandas.

Ví dụ:
    python tools/read_sessions.py sessions/20261103_090000_A_fall
    python tools/read_sessions.py Download/SafeNetCollector/*.zip --out data.npz
    python tools/read_sessions.py --selftest

Đầu vào có thể là: thư mục một buổi thu, thư mục chứa nhiều buổi (tìm đệ quy
meta.json / sensor.csv), hoặc file .zip do app xuất ra.

Đầu ra .npz:
    X          (N, 151, 3) float32  ax, ay, az (m/s², gồm trọng lực) đã resample 50 Hz
    y          (N,)        int8     1 = fall, 0 = khác
    label      (N,)        str      mã hoạt động (fall_forward, sit_hard, ...)
    subject    (N,)        str
    position   (N,)        str
    session_id (N,)        str
    trial_no   (N,)        int32
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

FS_HZ = 50
STEP_US = 1_000_000 // FS_HZ  # 20000 µs
WINDOW_KINDS = ("fall", "trap_short")


def _setup_stdout() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except Exception:
        pass


# ----------------------------------------------------------------------
# Đọc dữ liệu
# ----------------------------------------------------------------------


@dataclass
class Session:
    path: Path
    meta: dict
    sensor: pd.DataFrame
    events: pd.DataFrame
    health: pd.DataFrame
    warnings: list = field(default_factory=list)

    @property
    def session_id(self) -> str:
        return str(self.meta.get("session_id") or self.path.name)

    @property
    def subject(self) -> str:
        s = self.meta.get("subject")
        if s:
            return str(s)
        parts = self.path.name.split("_")
        return parts[2] if len(parts) >= 4 else "?"

    @property
    def position(self) -> str:
        return str(self.meta.get("phone_position") or "")


def find_session_dirs(inputs: list[str], tmp_root: Path) -> list[Path]:
    """Trả về danh sách thư mục buổi thu (có sensor.csv)."""
    found: list[Path] = []
    for i, raw in enumerate(inputs):
        p = Path(raw)
        if not p.exists():
            print(f"[!] Không tồn tại: {p}")
            continue
        if p.is_file() and p.suffix.lower() == ".zip":
            dest = tmp_root / f"zip{i}_{p.stem}"
            dest.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(p) as zf:
                for name in zf.namelist():
                    # chặn đường dẫn thoát khỏi thư mục giải nén
                    target = (dest / name).resolve()
                    if not str(target).startswith(str(dest.resolve())):
                        raise ValueError(f"Đường dẫn không hợp lệ trong zip: {name}")
                zf.extractall(dest)
            p = dest
        if p.is_dir():
            if (p / "sensor.csv").exists():
                found.append(p)
            else:
                found.extend(sorted(q.parent for q in p.rglob("sensor.csv")))
        else:
            print(f"[!] Bỏ qua (không phải thư mục/zip): {p}")
    # bỏ trùng, giữ thứ tự
    seen, out = set(), []
    for d in found:
        key = d.resolve()
        if key not in seen:
            seen.add(key)
            out.append(d)
    return out


def load_session(d: Path) -> Session:
    warns: list[str] = []
    meta: dict = {}
    if (d / "meta.json").exists():
        try:
            meta = json.loads((d / "meta.json").read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            warns.append(f"meta.json lỗi: {e}")
    else:
        warns.append("thiếu meta.json")

    sensor = pd.read_csv(d / "sensor.csv", on_bad_lines="skip")
    for c in ("t_us", "ax", "ay", "az", "recv_delay_ms"):
        sensor[c] = pd.to_numeric(sensor[c], errors="coerce")
    n0 = len(sensor)
    sensor = sensor.dropna(subset=["t_us", "ax", "ay", "az"])
    if len(sensor) < n0:
        warns.append(f"bỏ {n0 - len(sensor)} dòng sensor hỏng (thường là dòng cuối khi app bị kill)")
    sensor["t_us"] = sensor["t_us"].astype(np.int64)
    if not sensor["t_us"].is_monotonic_increasing:
        warns.append("t_us không tăng dần -> đã sắp xếp lại")
        sensor = sensor.sort_values("t_us", kind="stable")
    dup = sensor["t_us"].duplicated().sum()
    if dup:
        warns.append(f"bỏ {dup} mẫu trùng t_us")
        sensor = sensor.drop_duplicates("t_us")
    sensor = sensor.reset_index(drop=True)

    ev_path = d / "events.csv"
    if ev_path.exists():
        events = pd.read_csv(ev_path, dtype={"note": str, "label": str, "kind": str, "status": str})
        events["note"] = events["note"].fillna("")
    else:
        warns.append("thiếu events.csv")
        events = pd.DataFrame(columns=["t_start_us", "t_end_us", "label", "kind", "trial_no", "status", "note"])

    h_path = d / "health.csv"
    health = pd.read_csv(h_path) if h_path.exists() else pd.DataFrame()
    return Session(d, meta, sensor, events, health, warns)


# ----------------------------------------------------------------------
# Thống kê
# ----------------------------------------------------------------------


def _pct(a: np.ndarray, qs=(5, 50, 95, 99)) -> str:
    if a.size == 0:
        return "n/a"
    vals = np.percentile(a, qs)
    return ", ".join(f"p{q}={v:.1f}" for q, v in zip(qs, vals)) + f", max={a.max():.1f}"


def print_stats(s: Session) -> dict:
    t = s.sensor["t_us"].to_numpy()
    n = len(t)
    print(f"\n=== {s.session_id} ===")
    print(f"  thư mục   : {s.path}")
    print(f"  người thu : {s.subject} | vị trí: {s.position} | loại: {s.meta.get('session_type', '?')}")
    dev = s.meta.get("device") or {}
    if dev:
        acc = dev.get("accelerometer") or {}
        print(f"  máy       : {dev.get('manufacturer')} {dev.get('model')} (Android {dev.get('release')}, SDK {dev.get('sdkInt')})"
              f" | cảm biến: {acc.get('name')} maxRange={acc.get('maxRange')} fifo={acc.get('fifoMaxEventCount')}")
    for w in s.warnings:
        print(f"  [!] {w}")
    out = {"n": n, "gaps_1s": 0, "mean_hz": float("nan")}
    if n < 2:
        print("  (không đủ mẫu)")
        return out
    dur_s = (t[-1] - t[0]) / 1e6
    dt_ms = np.diff(t) / 1000.0
    mean_hz = (n - 1) / dur_s if dur_s > 0 else float("nan")
    gaps = int((dt_ms > 1000).sum())
    out.update(mean_hz=mean_hz, gaps_1s=gaps, duration_s=dur_s)
    print(f"  số mẫu    : {n}  | thời lượng: {dur_s / 60:.1f} phút | tần số TB: {mean_hz:.2f} Hz")
    print(f"  dt (ms)   : {_pct(dt_ms)}")
    bins = [0, 15, 25, 50, 100, 1000, np.inf]
    names = ["<15", "15-25", "25-50", "50-100", "100-1000", ">1000"]
    hist, _ = np.histogram(dt_ms, bins=bins)
    print("  phân phối dt: " + " | ".join(f"{nm}ms: {c} ({100 * c / len(dt_ms):.1f}%)" for nm, c in zip(names, hist)))
    print(f"  khoảng trống > 1 s: {gaps}" + (f" (lớn nhất {dt_ms.max() / 1000:.1f} s)" if gaps else ""))
    if "recv_delay_ms" in s.sensor:
        rd = s.sensor["recv_delay_ms"].dropna().to_numpy()
        print(f"  recv_delay_ms: {_pct(rd)}")
        if rd.size and np.percentile(rd, 95) > 200:
            print("  [!] recv_delay p95 > 200 ms: có batching/độ trễ khi chạy nền")

    ev = s.events
    if len(ev):
        real = ev[ev["kind"] != "note"]
        cnt = real.groupby(["kind", "status"]).size()
        print("  sự kiện  : " + ", ".join(f"{k}/{st}={c}" for (k, st), c in cnt.items())
              + f" | ghi chú: {int((ev['kind'] == 'note').sum())}")

    h = s.health
    if len(h):
        hz = pd.to_numeric(h.get("effective_hz"), errors="coerce")
        gap = pd.to_numeric(h.get("max_gap_ms"), errors="coerce")
        bat = pd.to_numeric(h.get("battery_pct"), errors="coerce").dropna()
        scr = pd.to_numeric(h.get("screen_on"), errors="coerce").dropna()
        print(f"  health    : {len(h)} dòng | effective_hz min={hz.min():.1f} TB={hz.mean():.1f}"
              f" | max_gap_ms lớn nhất={gap.max():.0f}"
              + (f" | pin {bat.iloc[0]:.0f}% -> {bat.iloc[-1]:.0f}%" if len(bat) else "")
              + (f" | màn hình tắt {100 * (scr == 0).mean():.0f}% thời gian" if len(scr) else ""))
        if "app_lifecycle" in h:
            lc = h["app_lifecycle"].value_counts().to_dict()
            print(f"  lifecycle : {lc}")
        bad = h[(hz < 45) | (gap > 5000)]
        if len(bad):
            print(f"  [!] {len(bad)} phút có Hz < 45 hoặc khoảng trống > 5 s")
    return out


# ----------------------------------------------------------------------
# Resample + cắt cửa sổ
# ----------------------------------------------------------------------


def resample(sensor: pd.DataFrame, step_us: int = STEP_US):
    """Nội suy tuyến tính về lưới đều. Trả về (grid_us, X[n,3], raw_gap_us[n])."""
    t = sensor["t_us"].to_numpy(dtype=np.int64)
    grid = np.arange(t[0], t[-1] + 1, step_us, dtype=np.int64)
    tf, gf = t.astype(np.float64), grid.astype(np.float64)
    X = np.stack([np.interp(gf, tf, sensor[c].to_numpy(dtype=np.float64)) for c in ("ax", "ay", "az")], axis=1)
    # khoảng cách giữa 2 mẫu gốc bao quanh mỗi điểm lưới (để loại cửa sổ nội suy qua lỗ hổng)
    idx = np.clip(np.searchsorted(t, grid, side="right"), 1, len(t) - 1)
    raw_gap = t[idx] - t[idx - 1]
    return grid, X, raw_gap


def extract_windows(s: Session, peak_index: int, window: int, max_gap_ms: float):
    out = []
    if len(s.sensor) < 2:
        return out
    grid, X, raw_gap = resample(s.sensor)
    mag = np.linalg.norm(X, axis=1)
    ev = s.events
    ev = ev[ev["kind"].isin(WINDOW_KINDS) & (ev["status"] == "ok")]
    for _, e in ev.iterrows():
        ts, te = int(e["t_start_us"]), int(e["t_end_us"])
        tag = f"{e['label']}#{e['trial_no']}"
        idxs = np.nonzero((grid >= ts) & (grid <= te))[0]
        if idxs.size == 0:
            print(f"  [!] {tag}: không có mẫu trong [t_start, t_end] -> bỏ")
            continue
        peak = int(idxs[np.argmax(mag[idxs])])
        a, b = peak - peak_index, peak - peak_index + window
        if a < 0 or b > len(grid):
            print(f"  [!] {tag}: đỉnh quá gần đầu/cuối bản ghi -> bỏ")
            continue
        g = raw_gap[a:b].max() / 1000.0
        if g > max_gap_ms:
            print(f"  [!] {tag}: cửa sổ chứa khoảng trống {g:.0f} ms > {max_gap_ms:.0f} ms -> bỏ")
            continue
        out.append({
            "X": X[a:b].astype(np.float32),
            "y": 1 if e["kind"] == "fall" else 0,
            "label": str(e["label"]),
            "subject": s.subject,
            "position": s.position,
            "session_id": s.session_id,
            "trial_no": int(e["trial_no"]),
            "peak_us": int(grid[peak]),
        })
    return out


def run(inputs: list[str], out_path: Path | None, peak_index: int, window: int, max_gap_ms: float) -> dict:
    if not 0 <= peak_index < window:
        raise SystemExit(f"--peak-index phải trong [0, {window - 1}]")
    with tempfile.TemporaryDirectory(prefix="safenet_") as tmp:
        dirs = find_session_dirs(inputs, Path(tmp))
        if not dirs:
            raise SystemExit("Không tìm thấy buổi thu nào (cần thư mục có sensor.csv hoặc file zip).")
        rows, stats = [], []
        for d in dirs:
            s = load_session(d)
            stats.append(print_stats(s))
            rows.extend(extract_windows(s, peak_index, window, max_gap_ms))

    print(f"\nTổng: {len(dirs)} buổi, {len(rows)} cửa sổ"
          f" (fall={sum(r['y'] for r in rows)}, khác={sum(1 - r['y'] for r in rows)})")
    result = {
        "X": np.stack([r["X"] for r in rows]) if rows else np.zeros((0, window, 3), np.float32),
        "y": np.array([r["y"] for r in rows], dtype=np.int8),
        "label": np.array([r["label"] for r in rows], dtype=str),
        "subject": np.array([r["subject"] for r in rows], dtype=str),
        "position": np.array([r["position"] for r in rows], dtype=str),
        "session_id": np.array([r["session_id"] for r in rows], dtype=str),
        "trial_no": np.array([r["trial_no"] for r in rows], dtype=np.int32),
    }
    if out_path is not None:
        np.savez_compressed(out_path, **result)
        print(f"Đã lưu {out_path}  X{result['X'].shape}")
    result["_stats"] = stats
    result["_peak_us"] = np.array([r["peak_us"] for r in rows], dtype=np.int64)
    return result


# ----------------------------------------------------------------------
# Selftest
# ----------------------------------------------------------------------


def _write_fake_session(root: Path, sid: str, subject: str, stype: str, t0: int, dur_s: float,
                        impacts: list[tuple], gap_at_s: float | None, rng) -> None:
    """impacts: (label, kind, status, trial_no, t_start_s, t_end_s, impact_s hoặc None)."""
    d = root / sid
    d.mkdir(parents=True)
    n = int(dur_s * 50)
    t = t0 + np.arange(n) * 20000 + rng.integers(-2000, 2000, n)
    t.sort()
    if gap_at_s is not None:  # lỗ hổng 1.5 s
        t = t[(t < t0 + gap_at_s * 1e6) | (t > t0 + (gap_at_s + 1.5) * 1e6)]
    ts = (t - t0) / 1e6
    ax = rng.normal(0, 0.3, t.size)
    ay = 9.81 + rng.normal(0, 0.3, t.size)
    az = rng.normal(0, 0.3, t.size)
    for _, _, _, _, _, _, imp in impacts:
        if imp is not None:
            bump = np.exp(-0.5 * ((ts - imp) / 0.05) ** 2)
            ax += 25 * bump
            az += 15 * bump
    delay = rng.uniform(1, 30, t.size)
    with open(d / "sensor.csv", "w", encoding="utf-8", newline="") as f:
        f.write("t_us,ax,ay,az,recv_delay_ms\n")
        for row in zip(t, ax, ay, az, delay):
            f.write(f"{row[0]},{row[1]:.4f},{row[2]:.4f},{row[3]:.4f},{row[4]:.1f}\n")
        f.write("1234567")  # dòng cuối dở dang như khi app bị kill
    with open(d / "events.csv", "w", encoding="utf-8", newline="") as f:
        f.write("t_start_us,t_end_us,label,kind,trial_no,status,note\n")
        for label, kind, status, trial, a, b, _ in impacts:
            f.write(f"{t0 + int(a * 1e6)},{t0 + int(b * 1e6)},{label},{kind},{trial},{status},\n")
        f.write(f'{t0 + 5_000_000},{t0 + 5_000_000},note,note,0,ok,"nệm 25cm, ""test"""\n')
    with open(d / "health.csv", "w", encoding="utf-8", newline="") as f:
        f.write("t_us,samples_last_min,effective_hz,max_gap_ms,battery_pct,screen_on,app_lifecycle\n")
        for m in range(1, int(dur_s // 60) + 1):
            f.write(f"{t0 + m * 60_000_000},3000,50.00,24.0,{90 - m},0,paused\n")
    meta = {
        "app_version": "selftest", "session_id": sid, "subject": subject,
        "phone_position": "pocket_front_trouser", "session_type": stype,
        "requested_sampling_us": 20000, "total_samples": int(t.size),
        "device": {"manufacturer": "Fake", "model": "Selftest", "sdkInt": 34, "release": "14",
                   "accelerometer": {"name": "fake-acc", "maxRange": 78.4, "fifoMaxEventCount": 0}},
    }
    (d / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")


def selftest(peak_index: int, window: int) -> None:
    rng = np.random.default_rng(0)
    t0 = 1_762_000_000_000_000
    with tempfile.TemporaryDirectory(prefix="safenet_selftest_") as tmp:
        root = Path(tmp)
        fall_ev = [
            ("fall_right", "fall", "ok", 1, 0.0, 4.0, 0.8),          # quá gần đầu -> bỏ
            ("fall_forward", "fall", "ok", 1, 10.0, 30.0, 14.37),     # giữ
            ("fall_backward", "fall", "redo", 1, 50.0, 70.0, 55.0),   # redo -> bỏ
            ("fall_backward", "fall", "ok", 1, 90.0, 110.0, 95.11),   # giữ
            ("fall_left", "fall", "aborted", 1, 130.0, 135.0, None),  # aborted -> bỏ
        ]
        _write_fake_session(root / "sessions", "20261103_090000_A_fall", "A", "fall",
                            t0, 150.0, fall_ev, gap_at_s=40.0, rng=rng)
        trap_ev = [
            ("sit_hard", "trap_short", "ok", 1, 10.0, 20.0, 13.02),   # giữ
            ("jump", "trap_short", "ok", 2, 30.0, 40.0, 33.8),        # cửa sổ chứa lỗ hổng -> bỏ
            ("walking", "trap_long", "ok", 1, 50.0, 110.0, None),     # trap_long -> không cắt
        ]
        _write_fake_session(root / "zipsrc", "20261103_100000_B_trap", "B", "trap",
                            t0 + 3_600_000_000, 120.0, trap_ev, gap_at_s=34.0, rng=rng)
        zpath = root / "B_trap.zip"
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
            for f in (root / "zipsrc").rglob("*"):
                if f.is_file():
                    zf.write(f, f.relative_to(root / "zipsrc").as_posix())

        out = root / "out.npz"
        res = run([str(root / "sessions"), str(zpath)], out, peak_index, window, max_gap_ms=100.0)

        with np.load(out) as npz:
            data = {k: npz[k] for k in npz.files}
        X, y = data["X"], data["y"]
        assert X.shape == (3, window, 3), X.shape
        assert y.tolist() == [1, 1, 0], y.tolist()
        assert data["label"].tolist() == ["fall_forward", "fall_backward", "sit_hard"], data["label"].tolist()
        assert data["subject"].tolist() == ["A", "A", "B"]
        assert data["session_id"].tolist()[2] == "20261103_100000_B_trap"
        assert data["trial_no"].dtype == np.int32
        for i in range(len(X)):
            assert int(np.argmax(np.linalg.norm(X[i], axis=1))) == peak_index, i
        expected_imp = np.array([t0 + 14.37e6, t0 + 95.11e6, t0 + 3_600_000_000 + 13.02e6])
        err_ms = np.abs(res["_peak_us"] - expected_imp) / 1000
        assert (err_ms <= 20).all(), err_ms
        assert abs(X[0, 0, 1] - 9.81) < 1.5, "trọng lực phải nằm ở trục y"
        st = res["_stats"]
        assert st[0]["gaps_1s"] == 1 and st[1]["gaps_1s"] == 1, st
        assert all(48 < s["mean_hz"] < 52 for s in st), st
    print("\nSELFTEST OK")


def main(argv=None) -> None:
    _setup_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", help="thư mục buổi thu / thư mục cha / file .zip")
    ap.add_argument("--out", default="safenet_windows.npz", help="file .npz đầu ra")
    ap.add_argument("--no-save", action="store_true", help="chỉ in thống kê, không ghi .npz")
    ap.add_argument("--peak-index", type=int, default=75, help="vị trí đỉnh trong cửa sổ (mặc định 75)")
    ap.add_argument("--window", type=int, default=151, help="độ dài cửa sổ (mặc định 151)")
    ap.add_argument("--max-gap-ms", type=float, default=100.0,
                    help="bỏ cửa sổ nếu dữ liệu gốc có khoảng trống lớn hơn (mặc định 100 ms)")
    ap.add_argument("--selftest", action="store_true", help="tự sinh dữ liệu giả và kiểm tra toàn bộ quy trình")
    args = ap.parse_args(argv)

    if args.selftest:
        selftest(args.peak_index, args.window)
        return
    if not args.inputs:
        ap.error("cần ít nhất một đường dẫn (hoặc --selftest)")
    run(args.inputs, None if args.no_save else Path(args.out), args.peak_index, args.window, args.max_gap_ms)


if __name__ == "__main__":
    main()
