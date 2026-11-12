#!/usr/bin/env python3
"""Herramienta E2E y auditor geometrico para Kids Police en Android Emulator:
Subcomandos:
  tap <xml> <regex>              -> imprime "cx cy label" del primer nodo coincidente
  tap_nth <xml> <regex> <idx>    -> imprime "cx cy label" del idx-esimo nodo coincidente (0-based)
  hangup_xy <xml>                -> imprime "cx cy" del boton rojo de colgar en ActiveCallScreen
  audit <results_dir> <screen_w> -> audita centrado horizontal en todos los ui_*.xml,
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
    matches = []
    for n in iter_nodes(xml_path):
        if n["combined"] and rx.search(n["combined"]):
            matches.append(n)
    if len(matches) > nth:
        m = matches[nth]
        lbl = re.sub(r"\s+", "_", m["combined"])[:42]
        print(f"{m['cx']} {m['cy']} {lbl}")


def cmd_hangup_xy(xml_path: str, screen_w: int = 1080, screen_h: int = 2400):
    # Busca el boton clickable mas a la derecha en la barra inferior de controles
    candidates = []
    for n in iter_nodes(xml_path):
        x1, y1, x2, y2 = n["bounds"]
        if n["clickable"] and y1 > int(screen_h * 0.78) and x1 > int(screen_w * 0.72):
            if 80 <= n["w"] <= 240 and 80 <= n["h"] <= 240:
                candidates.append(n)
    if candidates:
        c = sorted(candidates, key=lambda item: item["cx"], reverse=True)[0]
        print(f"{c['cx']} {c['cy']}")
    else:
        # Coordenada de respaldo en barra inferior derecha (1080x2400)
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
    # Zona central del rostro/torso del personaje (evita el reloj arriba y subtitulos abajo)
    crop_box = (int(w * 0.20), int(h * 0.18), int(w * 0.80), int(h * 0.56))
    c1 = im1.crop(crop_box)
    c2 = im2.crop(crop_box)
    diff = ImageChops.difference(c1, c2)
    stat = ImageStat.Stat(diff)
    mean_diff = sum(stat.mean) / 3.0
    # Tambien verificar que no sea pantalla negra (brillo medio > 25)
    bright = sum(ImageStat.Stat(c1).mean) / 3.0
    return {
        "checked": True,
        "mean_pixel_delta": round(mean_diff, 3),
        "mean_brightness": round(bright, 2),
        "video_moving": mean_diff > 1.2 and bright > 25.0,
    }


def cmd_audit(results_dir: str, screen_w: int):
    target_cx = screen_w / 2.0
    tolerance_px = max(28, int(screen_w * 0.035))  # ~37px en 1080p (3.5%)
    xml_files = sorted(glob.glob(os.path.join(results_dir, "ui_*.xml")))

    off_center_items = []
    checked_text_nodes = 0

    for xf in xml_files:
        base = os.path.basename(xf)
        if base in ("ui_t.xml", "ui_h.xml", "ui_anr.xml", "ui_ad.xml", "ui_dlg.xml"):
            continue
        nodes = list(iter_nodes(xf))
        for n in nodes:
            label = n["text"] or n["desc"]
            if not label:
                continue
            if not n["pkg"].startswith("com.superappsmx.kidspolice"):
                continue
            # Ignorar textos que pertenecen a grillas multicolumna (ancho < 46% de pantalla, como chips, 3 tarjetas de heroes, 2 botones Lado a Lado, teclado 3x3 o barra de 5 controles)
            if n["w"] < int(screen_w * 0.48):
                continue
            checked_text_nodes += 1
            delta = abs(n["cx"] - target_cx)
            if delta > tolerance_px:
                off_center_items.append(
                    {
                        "file": base,
                        "text": (n["text"] or n["desc"])[:65],
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
        "screen_width": screen_w,
        "expected_center_x": target_cx,
        "tolerance_px": tolerance_px,
        "checked_fullwidth_text_nodes": checked_text_nodes,
        "off_center_count": len(off_center_items),
        "off_center_items": off_center_items,
        "video_police_motion": vid_police,
        "video_doctor_motion": vid_doctor,
    }

    out_json = os.path.join(results_dir, "audit_report.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    md_lines = [
        "# Kids Police — Reporte E2E y Auditoría Geométrica de Centrado",
        f"- Ancho de pantalla: `{screen_w}px` (centro esperado `X = {target_cx}px`, tolerancia `±{tolerance_px}px`)",
        f"- Nodos de texto principales auditados en XML: `{checked_text_nodes}`",
        f"- Textos descentrados detectados: `{len(off_center_items)}`",
        f"- Videollamada Oficial Marco (movimiento real de fotogramas): `{vid_police}`",
        f"- Videollamada Dra. Elena (movimiento real de fotogramas): `{vid_doctor}`",
        "",
    ]
    if off_center_items:
        md_lines.append("## Elementos fuera de centro detectados")
        for it in off_center_items:
            md_lines.append(
                f"- `{it['file']}`: **{it['text']}** -> `cx={it['cx']}` (desviación `{it['delta_px']}px`, bounds `{it['bounds']}`)"
            )
    else:
        md_lines.append("## Centrado Horizontal: 100% APROBADO (0 desviaciones)")

    with open(os.path.join(results_dir, "audit_report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md_lines) + "\n")

    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "tap":
        cmd_tap(sys.argv[2], sys.argv[3], 0)
    elif cmd == "tap_nth":
        cmd_tap(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif cmd == "hangup_xy":
        cmd_hangup_xy(
            sys.argv[2],
            int(sys.argv[3]) if len(sys.argv) > 3 else 1080,
            int(sys.argv[4]) if len(sys.argv) > 4 else 2400,
        )
    elif cmd == "audit":
        cmd_audit(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1080)
