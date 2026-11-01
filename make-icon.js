#!/usr/bin/env node
// make-icon.js —— 从源图(白底 JPG/PNG)生成 macOS 应用 iconset
//
// 用法:node make-icon.js <源图.png> <输出 iconset 目录> [预览.png]
//
// 流程:sips 已把 JPG 转为 PNG → 本脚本解码 PNG → 白底转透明
// (对半透明边缘按“已知白底”做反预乘,消除白边)→ 盒式降采样出全套
// 尺寸 → 写 PNG(编码器与 gen-logo.js 同源)。
// 仅依赖 node 内置模块(zlib/Buffer)。

"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

// ---------------- PNG 解码(8-bit / colorType 0,2,4,6 / 非隔行) ----------------
function decodePNG(file) {
  const buf = fs.readFileSync(file);
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (!buf.slice(0, 8).equals(sig)) throw new Error("不是 PNG 文件");
  let off = 8, ihdr = null;
  const idat = [];
  while (off + 12 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("latin1", off + 4, off + 8);
    const data = buf.slice(off + 8, off + 8 + len);
    if (type === "IHDR") ihdr = data;
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    off += 12 + len;
  }
  if (!ihdr || !idat.length) throw new Error("PNG 缺少 IHDR/IDAT");
  const w = ihdr.readUInt32BE(0), h = ihdr.readUInt32BE(4);
  const depth = ihdr[8], ct = ihdr[9], interlace = ihdr[12];
  if (depth !== 8) throw new Error(`不支持位深 ${depth}`);
  if (interlace !== 0) throw new Error("不支持隔行 PNG");
  const chMap = { 0: 1, 2: 3, 4: 2, 6: 4 };
  const ch = chMap[ct];
  if (!ch) throw new Error(`不支持颜色类型 ${ct}`);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * ch;
  if (raw.length < h * (stride + 1)) throw new Error("PNG 数据不完整");
  const out = Buffer.alloc(h * stride);
  const paeth = (a, b, c) => {
    const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
  };
  let pos = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[pos++];
    const line = out.slice(y * stride, (y + 1) * stride);
    for (let x = 0; x < stride; x++) {
      const rb = raw[pos++];
      const a = x >= ch ? line[x - ch] : 0;
      const b = y > 0 ? out[(y - 1) * stride + x] : 0;
      const c = x >= ch && y > 0 ? out[(y - 1) * stride + x - ch] : 0;
      let v;
      if (f === 0) v = rb;
      else if (f === 1) v = rb + a;
      else if (f === 2) v = rb + b;
      else if (f === 3) v = rb + ((a + b) >> 1);
      else v = rb + paeth(a, b, c);
      line[x] = v & 0xff;
    }
  }
  // 转 RGBA
  const rgba = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    if (ct === 6) { rgba.copy(rgba, i * 4, 0, 0); }
    const s = i * ch, d = i * 4;
    if (ct === 0) { rgba[d] = rgba[d + 1] = rgba[d + 2] = out[s]; rgba[d + 3] = 255; }
    else if (ct === 4) { rgba[d] = rgba[d + 1] = rgba[d + 2] = out[s]; rgba[d + 3] = out[s + 1]; }
    else if (ct === 2) { rgba[d] = out[s]; rgba[d + 1] = out[s + 1]; rgba[d + 2] = out[s + 2]; rgba[d + 3] = 255; }
    else { rgba[d] = out[s]; rgba[d + 1] = out[s + 1]; rgba[d + 2] = out[s + 2]; rgba[d + 3] = out[s + 3]; }
  }
  return { w, h, rgba };
}

// ---------------- 白底转透明 + 反预乘去白边 ----------------
function keyOutWhite(img) {
  const { w, h, rgba } = img;
  const D0 = 0.015, D1 = 0.075;   // 距白的归一化距离阈值:低于 D0 全透明,高于 D1 全不透明
  for (let i = 0; i < w * h; i++) {
    const d = i * 4;
    const r = rgba[d], g = rgba[d + 1], b = rgba[d + 2];
    const dist = Math.sqrt((255 - r) ** 2 + (255 - g) ** 2 + (255 - b) ** 2) / 441.673;
    let a = (dist - D0) / (D1 - D0);
    a = a < 0 ? 0 : a > 1 ? 1 : a;
    if (a === 0) {
      rgba[d] = rgba[d + 1] = rgba[d + 2] = 0;
    } else if (a < 1) {
      // 观测色 = 真实色*a + 白*(1-a) → 反解真实色,消除白边
      rgba[d] = Math.max(0, Math.min(255, Math.round((r - 255 * (1 - a)) / a)));
      rgba[d + 1] = Math.max(0, Math.min(255, Math.round((g - 255 * (1 - a)) / a)));
      rgba[d + 2] = Math.max(0, Math.min(255, Math.round((b - 255 * (1 - a)) / a)));
    }
    rgba[d + 3] = Math.round(a * 255);
  }
  return img;
}

// ---------------- 圆拟合(主体为标准圆;质心 + 99.5% 分位半径) ----------------
function fitCircle(img) {
  const { w, h, rgba } = img;
  let sx = 0, sy = 0, n = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (rgba[(y * w + x) * 4 + 3] > 128) { sx += x; sy += y; n++; }
    }
  }
  if (n < 64) return null;
  const cx = sx / n, cy = sy / n;
  const ds = [];
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (rgba[(y * w + x) * 4 + 3] > 128) {
        ds.push(Math.hypot(x + 0.5 - cx, y + 0.5 - cy));
      }
    }
  }
  ds.sort((a, b) => a - b);
  return { cx, cy, R: ds[Math.floor(ds.length * 0.995)] };
}

// ---------------- 圆形掩膜(解析 1px AA;返回圆参数供后续步骤复用) ----------------
function circleMask(img) {
  const { w, h, rgba } = img;
  const circ = fitCircle(img);
  if (!circ) return null;
  const { cx, cy, R } = circ;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
      let a = R - d + 0.5;
      a = a < 0 ? 0 : a > 1 ? 1 : a;
      const i = (y * w + x) * 4;
      rgba[i + 3] = Math.round(a * 255);
      if (a === 0) rgba[i] = rgba[i + 1] = rgba[i + 2] = 0;
    }
  }
  return circ;
}

// ---------------- 底部水平擦除 ----------------
// 胸口被圆裁掉且切口处胸色与背景色几乎相同(实测 Δ≈5),泛洪必从那里渗入猫身。
// 改用水平线整体擦除 y ≥ cy+0.54R(≈757):胡须最低点 ≈720 不受影响;
// 该切线在合成后位于 squircle 底边之外(缩放使猫底溢出方块),成品不可见。
function eraseBottom(img, circ) {
  const { w, h, rgba } = img;
  const yCut = Math.min(h - 1, Math.round(circ.cy + 0.54 * circ.R));
  for (let y = yCut; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const p = (y * w + x) * 4;
      rgba[p] = rgba[p + 1] = rgba[p + 2] = rgba[p + 3] = 0;
    }
  }
  return img;
}

// ---------------- 背景移除(边缘泛洪) ----------------
// 实测:背景为平滑渐变(相邻像素差 <15),猫/胡须轮廓每像素跳变 ≥26(最大 141),
// 连续阈值 20 可靠阻挡;再以自适应逐级收紧兜底(以"猫身面积占比 ≥20%"验证,
// 防止某处薄弱点被渗过后吃掉整只猫)。
function floodBgMask(img, circ, continuity) {
  const { w, h, rgba } = img;
  const { cx, cy, R } = circ;
  const N = w * h;
  const isBg = new Uint8Array(N);
  const queue = new Int32Array(N);
  let qt = 0;
  const blueFamily = (p) => {
    const r = rgba[p], g = rgba[p + 1], b = rgba[p + 2];
    return b - r >= 30 && b >= g - 6 && g >= r - 6;    // 背景渐变恒为 b≥g≥r 且 b≫r
  };
  // 种子:圆周内圈 ring 的【确定背景扇区】。
  // 注意不能取整圈:猫胸被圆裁掉、直接接触圆周(约 5 点-7 点半方向),
  // 而 navy 猫身本身也是"蓝色族",整圈种子会从猫内部点火吃掉整只猫。
  // 只取 12 点→4 点半(θ ≤ 45°,屏幕角度 y 向下)——猫头远离该区圆周。
  const rIn = Math.max(0, R - 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x, p = i * 4;
      if (rgba[p + 3] === 0) continue;
      const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
      if (d <= rIn || d > R + 1) continue;
      const th = Math.atan2(y + 0.5 - cy, x + 0.5 - cx) * 180 / Math.PI;
      if (th <= 45 && blueFamily(p)) { isBg[i] = 1; queue[qt++] = i; }
    }
  }
  // BFS:仅向"与当前像素色差 ≤continuity 且属蓝色渐变族"的邻居扩散
  let qh = 0;
  while (qh < qt) {
    const i = queue[qh++];
    const p = i * 4;
    const r0 = rgba[p], g0 = rgba[p + 1], b0 = rgba[p + 2];
    const x = i % w, y = (i / w) | 0;
    const tryN = (j) => {
      if (isBg[j]) return;
      const q = j * 4;
      if (rgba[q + 3] === 0 || !blueFamily(q)) return;
      if (Math.max(Math.abs(rgba[q] - r0), Math.abs(rgba[q + 1] - g0), Math.abs(rgba[q + 2] - b0)) > continuity) return;
      isBg[j] = 1; queue[qt++] = j;
    };
    if (x > 0) tryN(i - 1);
    if (x < w - 1) tryN(i + 1);
    if (y > 0) tryN(i - w);
    if (y < h - 1) tryN(i + w);
  }
  return isBg;
}

function applyBgMask(img, isBg) {
  const { w, h, rgba } = img;
  // 夹缝残留:泛洪止步的噪点若 ≥3 邻居均为背景且属蓝族则一并清
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) {
      const i = y * w + x, p = i * 4;
      if (isBg[i] || rgba[p + 3] === 0) continue;
      let bgN = 0;
      for (const j of [i - 1, i + 1, i - w, i + w]) if (isBg[j] || rgba[j * 4 + 3] === 0) bgN++;
      if (bgN >= 3 && (rgba[p + 2] - rgba[p]) >= 40 && rgba[p + 2] >= rgba[p + 1] - 6) isBg[i] = 2;
    }
  }
  for (let i = 0; i < w * h; i++) {
    if (isBg[i]) { const p = i * 4; rgba[p] = rgba[p + 1] = rgba[p + 2] = rgba[p + 3] = 0; }
  }
  return img;
}

// ---------------- 最大连通域保留 ----------------
// 清除与主体不相连的一切残迹(JPEG 条带 ring、孤立噪点):8 连通标记,
// 只保留最大块及 ≥其 2% 的块(胡须与面部相连,不受影响)。
function keepLargestComponents(img) {
  const { w, h, rgba } = img;
  const N = w * h;
  const label = new Int32Array(N).fill(-1);
  const queue = new Int32Array(N);
  const sizes = [0];
  let comp = 0;
  for (let s = 0; s < N; s++) {
    if (label[s] !== -1 || rgba[s * 4 + 3] === 0) continue;
    comp++;
    let qt = 0, qh = 0;
    label[s] = comp; queue[qt++] = s;
    while (qh < qt) {
      const i = queue[qh++], x = i % w, y = (i / w) | 0;
      for (let dy = -1; dy <= 1; dy++) {
        const yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (let dx = -1; dx <= 1; dx++) {
          const xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          const j = yy * w + xx;
          if (label[j] !== -1 || rgba[j * 4 + 3] === 0) continue;
          label[j] = comp; queue[qt++] = j;
        }
      }
    }
    sizes[comp] = qt;
  }
  let largest = 0;
  for (let c = 1; c <= comp; c++) if (sizes[c] > sizes[largest]) largest = c;
  for (let c = 1; c <= comp; c++) {
    if (c === largest || sizes[c] * 50 >= sizes[largest]) continue;
    for (let i = 0; i < N; i++) {
      if (label[i] === c) { const p = i * 4; rgba[p] = rgba[p + 1] = rgba[p + 2] = rgba[p + 3] = 0; }
    }
  }
  return img;
}

function removeBackground(img, circ) {
  const { w, h, rgba } = img;
  const { cx, cy, R } = circ;
  const mopUp = () => {
    // 外圈清扫:0.88R 以外的蓝色族残留(JPEG 噪点环、挡泛洪的残迹)
    // (底部扇区已被 eraseBottom 擦除,无需扇区豁免)
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = y * w + x, p = i * 4;
        if (rgba[p + 3] === 0) continue;
        const dx = x + 0.5 - cx, dy = y + 0.5 - cy;
        if (Math.hypot(dx, dy) < 0.88 * R) continue;
        const r = rgba[p], g = rgba[p + 1], b = rgba[p + 2];
        if (b - r >= 30 && b >= g - 6 && g >= r - 6) rgba[p] = rgba[p + 1] = rgba[p + 2] = rgba[p + 3] = 0;
      }
    }
  };
  for (const cont of [20, 15, 10]) {
    const probe = Buffer.from(rgba);
    const mask = floodBgMask({ w, h, rgba: probe }, circ, cont);
    let opaque = 0, cat = 0;
    for (let i = 0; i < w * h; i++) {
      if (probe[i * 4 + 3] > 0) { opaque++; if (!mask[i]) cat++; }
    }
    if (opaque > 0 && cat / opaque >= 0.20) return mopUp(applyBgMask(img, mask));
  }
  return mopUp(applyBgMask(img, floodBgMask(img, circ, 10)));   // 兜底:最保守
}

// ---------------- 合成到白色圆形(整体圆形,圆外透明) ----------------
function composeOnCircle(img) {
  const { w, h, rgba } = img;
  // 猫的包围盒
  let minX = w, minY = h, maxX = 0, maxY = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (rgba[(y * w + x) * 4 + 3] > 8) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  const bw = maxX - minX + 1, bh = maxY - minY + 1;
  const CANVAS = 1024, C = CANVAS / 2, R = 470, GAP = 45;
  // 缩放:耳顶钉在圆顶下 GAP 处;同时保证胸口擦除线越出圆底(否则切口可见)。
  // 推导:ty = (C-R)+GAP - minY*s;切线终位 ty+(minY+bh)*s ≥ C+R+12 → s ≥ (2R-GAP-12)/bh
  const s = Math.min(Math.max((2 * R - GAP - 12) / bh, 1), (2 * R * 0.98) / bw);
  const tx = C - ((minX + maxX + 1) / 2) * s;
  const ty = (C - R) + GAP - minY * s;
  const out = Buffer.alloc(CANVAS * CANVAS * 4);
  const sample = (fx, fy) => {
    const x0 = Math.floor(fx), y0 = Math.floor(fy);
    if (x0 < 0 || y0 < 0 || x0 >= w - 1 || y0 >= h - 1) return null;
    const dx = fx - x0, dy = fy - y0;
    const acc = [0, 0, 0, 0];
    for (const [ox2, oy2, wgt] of [[0, 0, (1 - dx) * (1 - dy)], [1, 0, dx * (1 - dy)], [0, 1, (1 - dx) * dy], [1, 1, dx * dy]]) {
      const p = ((y0 + oy2) * w + (x0 + ox2)) * 4;
      for (let k = 0; k < 4; k++) acc[k] += rgba[p + k] * wgt;
    }
    return acc;
  };
  for (let y = 0; y < CANVAS; y++) {
    for (let x = 0; x < CANVAS; x++) {
      const i = (y * CANVAS + x) * 4;
      // 白底圆形(解析 1px 抗锯齿)
      const d = Math.hypot(x + 0.5 - C, y + 0.5 - C);
      const cov = Math.max(0, Math.min(1, R - d + 0.5));
      if (cov <= 0) continue;
      let aTile = cov, rT = 255, gT = 255, bT = 255;
      // 猫(双线性采样)alpha-over
      const c = sample((x + 0.5 - tx) / s, (y + 0.5 - ty) / s);
      if (c && c[3] > 0) {
        const aC = c[3] / 255;
        const oA = aC + aTile * (1 - aC);
        out[i] = Math.round((c[0] * aC + rT * aTile * (1 - aC)) / oA);
        out[i + 1] = Math.round((c[1] * aC + gT * aTile * (1 - aC)) / oA);
        out[i + 2] = Math.round((c[2] * aC + bT * aTile * (1 - aC)) / oA);
        out[i + 3] = Math.round(oA * 255);
      }
      else {
        out[i] = rT; out[i + 1] = gT; out[i + 2] = bT;
        out[i + 3] = Math.round(aTile * 255);
      }
    }
  }
  return { w: CANVAS, h: CANVAS, rgba: out };
}

// ---------------- 补白成正方形 ----------------
function padSquare(img) {
  const { w, h, rgba } = img;
  if (w === h) return img;
  const S = Math.max(w, h);
  const out = Buffer.alloc(S * S * 4);   // 全 0 = 全透明
  const ox = (S - w) >> 1, oy = (S - h) >> 1;
  for (let y = 0; y < h; y++) {
    rgba.copy(out, ((y + oy) * S + ox) * 4, y * w * 4, (y + 1) * w * 4);
  }
  return { w: S, h: S, rgba: out };
}

// ---------------- 盒式降采样(整数倍;预乘域平均,边缘不发黑) ----------------
function downscale(img, size) {
  const { w, h, rgba } = img;
  if (w % size || h % size) throw new Error(`尺寸 ${w}→${size} 非整数倍`);
  const k = w / size;
  const out = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let sr = 0, sg = 0, sb = 0, sa = 0;
      for (let dy = 0; dy < k; dy++) {
        for (let dx = 0; dx < k; dx++) {
          const d = (((y * k + dy) * w) + (x * k + dx)) * 4;
          const a = rgba[d + 3];
          sr += rgba[d] * a; sg += rgba[d + 1] * a; sb += rgba[d + 2] * a; sa += a;
        }
      }
      const n = k * k, d = (y * size + x) * 4;
      out[d + 3] = Math.round(sa / n);
      if (sa > 0) {
        out[d] = Math.round(sr / sa);
        out[d + 1] = Math.round(sg / sa);
        out[d + 2] = Math.round(sb / sa);
      }
    }
  }
  return out;
}

// ---------------- PNG 编码(与 gen-logo.js 同源) ----------------
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function writePNG(file, w, h, rgba) {
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    raw[y * (1 + w * 4)] = 0;
    rgba.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  fs.writeFileSync(file, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]));
}

// ---------------- 主流程 ----------------
const [src, outDir, preview] = process.argv.slice(2);
if (!src || !outDir) {
  console.error("用法:node make-icon.js <源图.png> <iconset目录> [预览.png]");
  process.exit(1);
}
// 以圆心为基准把图案放大到目标半径(缩小四周留白),双线性采样;随后重建掩膜锐化边缘
function zoomToRadius(img, targetR) {
  const circ = fitCircle(img);
  if (!circ) return img;
  const f = targetR / circ.R;
  if (!(f > 1.005) || f > 1.6) return img;
  const { w, h, rgba } = img;
  const out = Buffer.alloc(w * h * 4);
  const C = w / 2;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const fx = circ.cx + (x + 0.5 - C) / f;
      const fy = circ.cy + (y + 0.5 - C) / f;
      const x0 = Math.floor(fx), y0 = Math.floor(fy);
      const d = (y * w + x) * 4;
      if (x0 < 0 || y0 < 0 || x0 >= w - 1 || y0 >= h - 1) continue;
      const dx = fx - x0, dy = fy - y0;
      let r = 0, g = 0, b = 0, a = 0;
      for (const [ox, oy, wgt] of [[0, 0, (1 - dx) * (1 - dy)], [1, 0, dx * (1 - dy)], [0, 1, (1 - dx) * dy], [1, 1, dx * dy]]) {
        const p = ((y0 + oy) * w + (x0 + ox)) * 4;
        r += rgba[p] * wgt; g += rgba[p + 1] * wgt; b += rgba[p + 2] * wgt; a += rgba[p + 3] * wgt;
      }
      out[d] = Math.round(r); out[d + 1] = Math.round(g); out[d + 2] = Math.round(b); out[d + 3] = Math.round(a);
    }
  }
  return { w, h, rgba: out };
}

// 管线:忠实还原用户源图 —— 只做必要的"装裱"处理,图案内容原样保留:
//   1) 白底转透明(圆外四角,按已知白底反预乘消白边)
//   2) 圆掩膜重建边缘(JPEG 噪点毛边 → 干净 1px 抗锯齿圆)
//   3) 圆放大到贴近画布(四周留白收窄),再锐化一次边缘
let img = padSquare(keyOutWhite(decodePNG(src)));
circleMask(img);
img = zoomToRadius(img, 500);   // 1024 画布,圆直径 1000,四周各留 ~12px
circleMask(img);
const sizes = [
  ["icon_16x16.png", 16], ["icon_16x16@2x.png", 32],
  ["icon_32x32.png", 32], ["icon_32x32@2x.png", 64],
  ["icon_128x128.png", 128], ["icon_128x128@2x.png", 256],
  ["icon_256x256.png", 256], ["icon_256x256@2x.png", 512],
  ["icon_512x512.png", 512], ["icon_512x512@2x.png", 1024],
];
fs.mkdirSync(outDir, { recursive: true });
for (const [name, size] of sizes) {
  writePNG(path.join(outDir, name), size, size, size === img.w ? img.rgba : downscale(img, size));
  console.log(`  ${name} (${size})`);
}
if (preview) writePNG(preview, 512, 512, downscale(img, 512));
console.log(`iconset 已生成:${outDir}`);
