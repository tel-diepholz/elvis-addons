#!/usr/bin/env python3
"""Führt die Kachelpyramide eines Bundeslandes in die gemeinsame ein.

Aufruf: merge.py <quelle> <ziel>. Kacheln, die es nur in der Quelle gibt, werden verschoben;
an Landesgrenzen vorhandene Kacheln werden über den Alphakanal übereinandergelegt.
"""
import os, sys
import numpy as np
from osgeo import gdal

gdal.UseExceptions()


def read(path):
    return gdal.Open(path).ReadAsArray().astype(np.float32)


def compose(src, dst):
    s, d = read(src), read(dst)
    if s.shape[0] != 4 or d.shape[0] != 4:
        return
    sa, da = s[3:] / 255, d[3:] / 255
    out_a = sa + da * (1 - sa)
    rgb = (s[:3] * sa + d[:3] * da * (1 - sa)) / np.maximum(out_a, 1e-6)
    out = np.concatenate([rgb, out_a * 255]).round().clip(0, 255).astype(np.uint8)
    mem = gdal.GetDriverByName('MEM').Create('', out.shape[2], out.shape[1], 4, gdal.GDT_Byte)
    for i in range(4):
        mem.GetRasterBand(i + 1).WriteArray(out[i])
    gdal.GetDriverByName('PNG').CreateCopy(dst + '.tmp', mem)
    os.replace(dst + '.tmp', dst)


def main(src_root, dst_root):
    for dirpath, _, files in os.walk(src_root):
        rel = os.path.relpath(dirpath, src_root)
        os.makedirs(os.path.join(dst_root, rel), exist_ok=True)
        for f in files:
            if not f.endswith('.png'):
                continue
            src, dst = os.path.join(dirpath, f), os.path.join(dst_root, rel, f)
            if os.path.exists(dst):
                compose(src, dst)
            else:
                os.replace(src, dst)


main(*sys.argv[1:3])
