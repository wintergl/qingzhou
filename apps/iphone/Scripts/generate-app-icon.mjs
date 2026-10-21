import fs from "node:fs";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const outputPath = fileURLToPath(new URL("../App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", import.meta.url));
const width = 1024;
const height = 1024;
const pixels = Buffer.alloc(width * height * 4);

const clamp = (value, min = 0, max = 1) => Math.max(min, Math.min(max, value));
const mix = (left, right, t) => left + (right - left) * t;
const smoothstep = (edge0, edge1, value) => {
  const t = clamp((value - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
};
const color = (hexValue) => [
  Number.parseInt(hexValue.slice(1, 3), 16),
  Number.parseInt(hexValue.slice(3, 5), 16),
  Number.parseInt(hexValue.slice(5, 7), 16),
];

function setPixel(x, y, rgba, alpha = 1) {
  if (x < 0 || y < 0 || x >= width || y >= height) return;
  const offset = (y * width + x) * 4;
  const nextAlpha = clamp(alpha);
  pixels[offset] = Math.round(mix(pixels[offset], rgba[0], nextAlpha));
  pixels[offset + 1] = Math.round(mix(pixels[offset + 1], rgba[1], nextAlpha));
  pixels[offset + 2] = Math.round(mix(pixels[offset + 2], rgba[2], nextAlpha));
  pixels[offset + 3] = 255;
}

function distanceToLine(px, py, ax, ay, bx, by) {
  const vx = bx - ax;
  const vy = by - ay;
  const wx = px - ax;
  const wy = py - ay;
  const t = clamp((wx * vx + wy * vy) / (vx * vx + vy * vy));
  return Math.hypot(px - (ax + t * vx), py - (ay + t * vy));
}

function roundedRectDistance(x, y, centerX, centerY, rectWidth, rectHeight, radius) {
  const qx = Math.abs(x - centerX) - rectWidth / 2 + radius;
  const qy = Math.abs(y - centerY) - rectHeight / 2 + radius;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - radius;
}

function isInsidePolygon(x, y, points) {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const [xi, yi] = points[i];
    const [xj, yj] = points[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

function polygonDistance(x, y, points) {
  let distance = Number.POSITIVE_INFINITY;
  for (let i = 0; i < points.length; i++) {
    const [ax, ay] = points[i];
    const [bx, by] = points[(i + 1) % points.length];
    distance = Math.min(distance, distanceToLine(x, y, ax, ay, bx, by));
  }
  return isInsidePolygon(x, y, points) ? -distance : distance;
}

function drawSignedDistance(colorForPoint, alphaForPoint) {
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const sampleX = x + 0.5;
      const sampleY = y + 0.5;
      const alpha = alphaForPoint(sampleX, sampleY);
      if (alpha > 0) setPixel(x, y, colorForPoint(sampleX, sampleY), alpha);
    }
  }
}

function drawStroke(points, strokeWidth, strokeColor) {
  drawSignedDistance(
    () => strokeColor,
    (x, y) => {
      let distance = Number.POSITIVE_INFINITY;
      for (let i = 0; i < points.length - 1; i++) {
        distance = Math.min(
          distance,
          distanceToLine(x, y, points[i][0], points[i][1], points[i + 1][0], points[i + 1][1]),
        );
      }
      return 1 - smoothstep(strokeWidth - 1, strokeWidth + 2, distance);
    },
  );
}

function crc32(buffer) {
  let crc = ~0;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return ~crc >>> 0;
}

function pngChunk(type, bytes) {
  const typeBuffer = Buffer.from(type);
  const lengthBuffer = Buffer.alloc(4);
  lengthBuffer.writeUInt32BE(bytes.length);
  const crcBuffer = Buffer.alloc(4);
  crcBuffer.writeUInt32BE(crc32(Buffer.concat([typeBuffer, bytes])));
  return Buffer.concat([lengthBuffer, typeBuffer, bytes, crcBuffer]);
}

const backgroundTop = color("#07111f");
const backgroundBottom = color("#12335e");
const glow = color("#0b7f84");

for (let y = 0; y < height; y++) {
  for (let x = 0; x < width; x++) {
    const nx = x / (width - 1);
    const ny = y / (height - 1);
    const radial = clamp(1 - Math.hypot(nx - 0.78, ny - 0.18) * 1.1);
    const vertical = clamp(0.72 * ny + 0.28 * nx);
    let next = [
      mix(backgroundTop[0], backgroundBottom[0], vertical),
      mix(backgroundTop[1], backgroundBottom[1], vertical),
      mix(backgroundTop[2], backgroundBottom[2], vertical),
    ];
    next = [
      mix(next[0], glow[0], radial * 0.55),
      mix(next[1], glow[1], radial * 0.55),
      mix(next[2], glow[2], radial * 0.55),
    ];
    setPixel(x, y, next, 1);
  }
}

drawSignedDistance(
  (x, y) => {
    const t = y / height;
    return [mix(17, 24, t), mix(45, 70, t), mix(79, 98, t)];
  },
  (x, y) => 0.22 * (1 - smoothstep(-2, 2, roundedRectDistance(x, y, 512, 512, 790, 790, 190))),
);

const shield = [
  [512, 188],
  [718, 270],
  [680, 586],
  [512, 818],
  [344, 586],
  [306, 270],
];
const shieldInner = [
  [512, 238],
  [666, 300],
  [637, 565],
  [512, 744],
  [387, 565],
  [358, 300],
];

drawSignedDistance(
  (x, y) => {
    const t = y / height;
    return [mix(28, 8, t), mix(168, 214, t), mix(154, 190, t)];
  },
  (x, y) => 0.97 * (1 - smoothstep(-3, 3, polygonDistance(x, y, shield))),
);
drawSignedDistance(
  (x, y) => {
    const t = y / height;
    return [mix(11, 18, t), mix(32, 64, t), mix(58, 91, t)];
  },
  (x, y) => 0.94 * (1 - smoothstep(-3, 3, polygonDistance(x, y, shieldInner))),
);

drawStroke([[512, 305], [512, 474]], 34, color("#e9fbff"));
drawStroke([[512, 474], [392, 596], [392, 666]], 34, color("#62e0d1"));
drawStroke([[512, 474], [632, 596], [632, 666]], 34, color("#7aa7ff"));
drawStroke([[460, 402], [460, 374], [512, 344], [564, 374], [564, 402]], 18, color("#c7f5ff"));

for (const [centerX, centerY, radius, fill] of [
  [512, 296, 48, "#e9fbff"],
  [392, 682, 48, "#65ead9"],
  [632, 682, 48, "#8ab0ff"],
  [512, 474, 42, "#ffffff"],
]) {
  drawSignedDistance(
    () => color(fill),
    (x, y) => 0.98 * (1 - smoothstep(radius - 2, radius + 2, Math.hypot(x - centerX, y - centerY))),
  );
}

const raw = Buffer.alloc((width * 4 + 1) * height);
for (let y = 0; y < height; y++) {
  raw[y * (width * 4 + 1)] = 0;
  pixels.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(width, 0);
ihdr.writeUInt32BE(height, 4);
ihdr[8] = 8;
ihdr[9] = 6;

const png = Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  pngChunk("IHDR", ihdr),
  pngChunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
  pngChunk("IEND", Buffer.alloc(0)),
]);

fs.writeFileSync(outputPath, png);
console.log(`Generated ${outputPath}`);
