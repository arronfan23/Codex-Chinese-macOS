#!/usr/bin/env node
// gen-logo.js —— 生成『Codex 中文启动器』应用图标(绿色 Codex 风格六瓣花)
//
// 用法:node gen-logo.js <输出目录>       # 生成 iconset 全尺寸 PNG
//       node gen-logo.js <输出.png> 1024 # 生成单张预览
//
// 仅依赖 node 内置模块(zlib/Buffer);icns 由 build-dmg.sh 调 iconutil 完成。
// 设计:深色 squircle 底 + 绿→蓝品牌渐变六瓣花(SMO 品牌色),4x 超采样抗锯齿。

"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

// ---------- 品牌 ----------
const GREEN = [16, 217, 126];    // #10D97E
const BLUE = [51, 102, 255];     // #3366FF
const BG_TOP = [22, 27, 34];     // 底色上(#161B22)
const BG_BOT = [10, 13, 18];     // 底色下(#0A0D12)

// ---------- PNG 编码 ----------
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
    raw[y * (1 + w * 4)] = 0; // filter: None
    rgba.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8bit RGBA
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  fs.writeFileSync(file, png);
}

// ---------- 形状 ----------
// 圆角矩形(squircle 近似)sigmoid 距离:<=0 在内部
function roundedRectDist(x, y, half, r) {
  const qx = Math.abs(x) - (half - r);
  const qy = Math.abs(y) - (half - r);
  const ox = Math.max(qx, 0), oy = Math.max(qy, 0);
  return Math.sqrt(ox * ox + oy * oy) + Math.min(Math.max(qx, qy), 0) - r;
}
// 六瓣花(Codex/OpenAI 风格):6 个绕心旋转的切向椭圆瓣,中心留小孔
function petalDist(x, y, R, a, b) {
  let d = Infinity;
  for (let i = 0; i < 6; i++) {
    const th = (i * Math.PI) / 3;
    const c = Math.cos(th), s = Math.sin(th);
    // 旋转到瓣局部坐标(径向 v,切向 u)
    const u = -x * s + y * c;
    const v = x * c + y * s;
    const du = u / a, dv = (v - R) / b;
    d = Math.min(d, Math.sqrt(du * du + dv * dv));
  }
  return d;
}

// ---------- 渲染 ----------
function render(size) {
  const px = Buffer.alloc(size * size * 4);
  const SS = 4; // 超采样
  const half = size / 2;
  const rRect = size * 0.225;   // 底圆角
  const R = size * 0.335;       // 花环半径
  const aLen = size * 0.150;    // 瓣切向半长(短瓣,相邻留间隙)
  const bLen = size * 0.088;    // 瓣径向半宽
  const hole = size * 0.105;    // 中心孔半径
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let rAcc = 0, gAcc = 0, bAcc = 0, aAcc = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const fx = x + (sx + 0.5) / SS - half;
          const fy = y + (sy + 0.5) / SS - half;
          let rC, gC, bC, aC;
          if (roundedRectDist(fx, fy, half - 0.5, rRect) <= 0) {
            // 底:垂直渐变
            const t = Math.min(1, Math.max(0, (fy + half) / size));
            rC = BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t;
            gC = BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t;
            bC = BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t;
            // 花:绿→蓝按 y 渐变(与 SMO 横幅一致)
            const pd = petalDist(fx, fy, R, aLen, bLen);
            if (pd <= 1 && Math.hypot(fx, fy) > hole) {
              const gt = Math.min(1, Math.max(0, (fy + R + aLen) / (2 * (R + aLen))));
              rC = GREEN[0] + (BLUE[0] - GREEN[0]) * gt;
              gC = GREEN[1] + (BLUE[1] - GREEN[1]) * gt;
              bC = GREEN[2] + (BLUE[2] - GREEN[2]) * gt;
            }
            aC = 255;
          } else { rC = 0; gC = 0; bC = 0; aC = 0; }
          rAcc += rC; gAcc += gC; bAcc += bC; aAcc += aC;
        }
      }
      const n = SS * SS, i = (y * size + x) * 4;
      px[i] = Math.round(rAcc / n); px[i + 1] = Math.round(gAcc / n);
      px[i + 2] = Math.round(bAcc / n); px[i + 3] = Math.round(aAcc / n);
    }
  }
  return px;
}

// ---------- 入口 ----------
const arg1 = process.argv[2];
if (!arg1) { console.error("用法:node gen-logo.js <iconset目录|输出.png> [尺寸]"); process.exit(1); }
if (arg1.endsWith(".png")) {
  const size = parseInt(process.argv[3] || "1024", 10);
  writePNG(arg1, size, size, render(size));
  console.log(`已生成 ${arg1} (${size}x${size})`);
} else {
  const sizes = [
    ["icon_16x16.png", 16], ["icon_16x16@2x.png", 32],
    ["icon_32x32.png", 32], ["icon_32x32@2x.png", 64],
    ["icon_128x128.png", 128], ["icon_128x128@2x.png", 256],
    ["icon_256x256.png", 256], ["icon_256x256@2x.png", 512],
    ["icon_512x512.png", 512], ["icon_512x512@2x.png", 1024],
  ];
  fs.mkdirSync(arg1, { recursive: true });
  for (const [name, size] of sizes) {
    writePNG(path.join(arg1, name), size, size, render(size));
    console.log(`  ${name} (${size})`);
  }
  console.log(`iconset 已生成:${arg1}`);
}
