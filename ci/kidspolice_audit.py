#!/usr/bin/env python3
"""Herramienta E2E y auditor geometrico multi-resolucion para Callabit (com.superappsmx.kidspolice):
Subcomandos:
  tap <xml> <regex>                -> imprime "cx cy label" del primer nodo coincidente
  tap_nth <xml> <regex> <idx>      -> imprime "cx cy label" del idx-esimo nodo coincidente (0-based)
  solve_gate <xml>                 -> resuelve reto matematico "A × B ?" de ParentalGateModal e imprime
                                      "answer edit_cx edit_cy btn_cx btn_cy"
  hangup_xy <xml> <sw> <sh>        -> imprime "cx cy" del boton rojo de colgar en ActiveCallScreen
  audit <results_dir> <default_sw> -> audita centrado horizontal en todos los ui_*.xml
                                      (1080p estandar, 720p compacto y 1200p tablet),
                                      verifica movimiento real de pixeles entre frames de videollamada,
                                      y genera audit_report.json + audit_report.md
"""
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET


def parse_bounds(b_str: str):
    nums = list(map(int, re.findall(r"\d+", b_str or "")))
    if len(nums) != 4:
        return None
    x1, y1, x2, y2 = nums
    if x2 <= x1 or y2 <= y1:
        return None
    return x1, y1, x2, y2


def iter_nodes(xml_path: str):
    if not os.path.isfile(xml_path):
        return
    try:
        tree = ET.parse(xml_path)
    except Exception:
        return
    for elem in tree.iter("node"):
        b = parse_bounds(elem.attrib.get("bounds", ""))
        if not b:
            continue
        txt = (elem.attrib.get("text") or "").strip()
        desc = (elem.attrib.get("content-desc") or "").strip()
        cls = elem.attrib.get("class") or ""
        pkg = elem.attrib.get("package") or ""
        clickable = elem.attrib.get("clickable") == "true"
        yield {
            "text": txt,
            "desc": desc,
            "combined": f"{txt} {desc}".strip(),
            "class": cls,
            "pkg": pkg,
            "clickable": clickable,
            "bounds": b,
            "cx": (b[0] + b[2]) // 2,
            "cy": (b[1] + b[3]) // 2,
            "w": b[2] - b[0],
            "h": b[3] - b[1],
        }


def cmd_tap(xml_path: str, pattern: str, nth: int = 0):
    rx = re.compile(pattern, re.I)
    clickable_matches = []
    other_matches = []
    for n in iter_nodes(xml_path):
        if n["combined"] and rx.search(n["combined"]):
            if n["clickable"]:
                clickable_matches.append(n)
            else:
                other_matches.append(n)
    matches = clickable_matches if clickable_matches else other_matches
    if len(matches) > nth:
        m = matches[nth]
        lbl = re.sub(r"\s+", "_", m["combined"])[:48]
        print(f"{m['cx']} {m['cy']} {lbl}")


def cmd_solve_gate(xml_path: str):
    nodes = list(iter_nodes(xml_path))
    if not nodes:
        return
    rx_math = re.compile(r"(\d{1,3})\s*[×x*]\s*(\d{1,3})")
    rx_confirm = re.compile(r"^(Continuar|Continue|Weiter|Continuer|متابعة)$", re.I)

    ans = None
    edit_node = None
    btn_node = None

    for n in nodes:
        if ans is None and n["combined"]:
            m = rx_math.search(n["combined"])
            if m:
                ans = int(m.group(1)) * int(m.group(2))
        if edit_node is None and "EditText" in n["class"]:
            edit_node = n
        if btn_node is None and (
            rx_confirm.search(n["text"]) or rx_confirm.search(n["desc"]) or rx_confirm.search(n["combined"])
        ):
            btn_node = n

    if ans is not None and edit_node is not None:
        bx = btn_node["cx"] if btn_node else edit_node["cx"]
        by = btn_node["cy"] if btn_node else (edit_node["cy"] + 160)
        print(f"{ans} {edit_node['cx']} {edit_node['cy']} {bx} {by}")


def cmd_hangup_xy(xml_path: str, screen_w: int = 1080, screen_h: int = 2400):
    min_dim = max(48, int(screen_w * 0.06))
    max_dim = max(260, int(screen_w * 0.28))
    candidates = []
    for n in iter_nodes(xml_path):
        x1, y1, _, _ = n["bounds"]
        if n["clickable"] and y1 > int(screen_h * 0.76) and x1 > int(screen_w * 0.70):
            if min_dim <= n["w"] <= max_dim and min_dim <= n["h"] <= max_dim:
                candidates.append(n)
    if candidates:
        c = sorted(candidates, key=lambda item: item["cx"], reverse=True)[0]
        print(f"{c['cx']} {c['cy']}")
    else:
        print(f"{int(screen_w * 0.885)} {int(screen_h * 0.915)}")


def check_video_motion(img1_path: str, img2_path: str):
    try:
        from PIL import Image, ImageChops, ImageStat
    except ImportError:
        return {"checked": False, "reason": "Pillow no instalado"}
    if not (os.path.isfile(img1_path) and os.path.isfile(img2_path)):
        return {"checked": False, "reason": "Faltan capturas de video"}

    im1 = Image.open(img1_path).convert("RGB")
    im2 = Image.open(img2_path).convert("RGB")
    w, h = im1.size
    crop_box = (int(w * 0.20), int(h * 0.18), int(w * 0.80), int(h * 0.56))
    c1 = im1.crop(crop_box)
    c2 = im2.crop(crop_box)
    diff = ImageChops.difference(c1, c2)
    stat = ImageStat.Stat(diff)
    mean_diff = sum(stat.mean) / 3.0
    bright = sum(ImageStat.Stat(c1).mean) / 3.0
    return {
        "checked": True,
        "mean_pixel_delta": round(mean_diff, 3),
        "mean_brightness": round(bright, 2),
        "video_moving": mean_diff > 1.2 and bright > 25.0,
    }


def resolve_viewport_width(base_name: str, default_sw: int) -> tuple[str, int]:
    if base_name.startswith("ui_compact_"):
        return "compact_720x1280", 720
    if base_name.startswith("ui_tablet_"):
        return "tablet_1200x1920", 1200
    return f"standard_{default_sw}p", default_sw


def cmd_audit(results_dir: str, default_sw: int):
    xml_files = sorted(glob.glob(os.path.join(results_dir, "ui_*.xml")))
    skip_exact = {
        "ui_t.xml",
        "ui_h.xml",
        "ui_anr.xml",
        "ui_ad.xml",
        "ui_dlg.xml",
        "ui_gate_tmp.xml",
        "ui_gate_tmp2.xml",
    }

    off_center_items = []
    checked_text_nodes = 0
    viewport_stats: dict[str, dict[str, int]] = {}

    for xf in xml_files:
        base = os.path.basename(xf)
        if base in skip_exact or base.startswith("ui_tmp_"):
            continue
        vp_key, vw = resolve_viewport_width(base, default_sw)
        target_cx = vw / 2.0
        tolerance_px = max(26, int(vw * 0.035))
        vp_bucket = viewport_stats.setdefault(vp_key, {"files": 0, "checked_nodes": 0, "off_center": 0})
        vp_bucket["files"] += 1

        nodes = list(iter_nodes(xf))
        switches = [s for s in nodes if "Switch" in s["class"] or "CheckBox" in s["class"]]

        for n in nodes:
            label = n["text"] or n["desc"]
            if not label:
                continue
            if not n["pkg"].startswith("com.superappsmx.kidspolice"):
                continue
            if "Switch" in n["class"] or "EditText" in n["class"]:
                continue
            # Ignorar textos en filas con Switch lateral (p. ej. Recordatorio 24h [Texto | Switch])
            if any(abs(n["cy"] - sw["cy"]) < 85 for sw in switches):
                continue
            # Ignorar textos que pertenecen a grillas multicolumna (ancho < 48% del viewport)
            if n["w"] < int(vw * 0.48):
                continue

            checked_text_nodes += 1
            vp_bucket["checked_nodes"] += 1
            delta = abs(n["cx"] - target_cx)
            if delta > tolerance_px:
                vp_bucket["off_center"] += 1
                off_center_items.append(
                    {
                        "file": base,
                        "viewport": vp_key,
                        "text": label[:65],
                        "bounds": n["bounds"],
                        "cx": n["cx"],
                        "expected_cx": target_cx,
                        "delta_px": round(delta, 1),
                    }
                )

    vid_police = check_video_motion(
        os.path.join(results_dir, "18a_video_police_f1.png"),
        os.path.join(results_dir, "18b_video_police_f2.png"),
    )
    vid_doctor = check_video_motion(
        os.path.join(results_dir, "19a_video_doctor_f1.png"),
        os.path.join(results_dir, "19b_video_doctor_f2.png"),
    )

    report = {
        "default_screen_width": default_sw,
        "checked_fullwidth_text_nodes": checked_text_nodes,
        "viewport_breakdown": viewport_stats,
        "off_center_count": len(off_center_items),
        "off_center_items": off_center_items,
        "video_police_motion": vid_police,
        "video_doctor_motion": vid_doctor,
    }

    out_json = os.path.join(results_dir, "audit_report.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    md_lines = [
        "# Callabit v1.1.0 — Reporte E2E Multi-Dispositivo y Auditoría Geométrica",
        f"- Total nodos de texto principales auditados en XML: `{checked_text_nodes}`",
        f"- Desglose por resolución (Estándar / Compacto 720p / Tablet 1200p): `{json.dumps(viewport_stats, ensure_ascii=False)}`",
        f"- Textos descentrados detectados: `{len(off_center_items)}`",
        f"- Videollamada Capitán Marco (movimiento real de fotogramas): `{vid_police}`",
        f"- Videollamada Dra. Elena (movimiento real de fotogramas): `{vid_doctor}`",
        "",
    ]
    if off_center_items:
        md_lines.append("## Elementos fuera de centro detectados")
        for it in off_center_items:
            md_lines.append(
                f"- `{it['file']}` ({it['viewport']}): **{it['text']}** -> `cx={it['cx']}` (esperado `{it['expected_cx']}`, desviación `{it['delta_px']}px`, bounds `{it['bounds']}`)"
            )
    else:
        md_lines.append("## Centrado Horizontal Multi-Resolución: 100% APROBADO (0 desviaciones)")

    with open(os.path.join(results_dir, "audit_report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md_lines) + "\n")

    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "tap":
        cmd_tap(sys.argv[2], sys.argv[3], 0)
    elif cmd == "tap_nth":
        cmd_tap(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif cmd == "solve_gate":
        cmd_solve_gate(sys.argv[2])
    elif cmd == "hangup_xy":
        cmd_hangup_xy(
            sys.argv[2],
            int(sys.argv[3]) if len(sys.argv) > 3 else 1080,
            int(sys.argv[4]) if len(sys.argv) > 4 else 2400,
        )
    elif cmd == "audit":
        cmd_audit(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1080)
