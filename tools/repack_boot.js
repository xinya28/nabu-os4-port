#!/usr/bin/env node
/*
 * Replace the kernel inside an Android boot.img (header v3) without touching
 * the ramdisk, cmdline or any other header field.
 *
 *   usage: node repack_boot.js <stock-boot.img> <Image> <out-boot.img>
 *
 * nabu (Xiaomi Pad 5) uses header v3: 1580-byte header, kernel on page 1,
 * ramdisk page-aligned after the kernel, and the DTB lives in vendor_boot -
 * so the boot partition only needs a raw arm64 Image.
 */
const fs = require('fs');

const [stockPath, imagePath, outPath] = process.argv.slice(2);
if (!stockPath || !imagePath || !outPath) {
  console.error('usage: node repack_boot.js <stock-boot.img> <Image> <out-boot.img>');
  process.exit(2);
}

const PAGE = 4096;
const stock = fs.readFileSync(stockPath);
const kernel = fs.readFileSync(imagePath);

if (stock.subarray(0, 8).toString('latin1') !== 'ANDROID!') {
  console.error('ERROR: stock image is not an Android boot image');
  process.exit(1);
}
const headerVersion = stock.readUInt32LE(40);
if (headerVersion !== 3) {
  console.error('ERROR: only header v3 is supported, got v' + headerVersion);
  process.exit(1);
}
if (kernel.length < 0x1000 || kernel.subarray(0x38, 0x3c).toString('latin1') !== 'ARMd') {
  console.error('ERROR: new kernel is not a raw arm64 Image (ARMd magic @0x38)');
  process.exit(1);
}

const oldKernelSize = stock.readUInt32LE(8);
const ramdiskSize = stock.readUInt32LE(12);   // v3: kernel_size@8, ramdisk_size@12, os_version@16, header_size@20
const oldRamdiskStart = PAGE + Math.ceil(oldKernelSize / PAGE) * PAGE;
const newKernelSize = kernel.length;
const newKernelPages = Math.ceil(newKernelSize / PAGE);
const newRamdiskStart = PAGE + newKernelPages * PAGE;

const header = Buffer.from(stock.subarray(0, PAGE)); // page 0, header + zero padding
header.writeUInt32LE(newKernelSize, 8);

const ramdisk = stock.subarray(oldRamdiskStart, oldRamdiskStart + ramdiskSize);
if (ramdisk.length !== ramdiskSize) {
  console.error('ERROR: truncated ramdisk in stock image');
  process.exit(1);
}

const out = Buffer.alloc(Math.max(newRamdiskStart + ramdiskSize, stock.length)); // pad to the stock partition dump
header.copy(out, 0);
kernel.copy(out, PAGE);
ramdisk.copy(out, newRamdiskStart);
fs.writeFileSync(outPath, out);

const pad = (n) => String(n).padStart(10);
console.log('stock   : kernel ' + pad(oldKernelSize) + ' B, ramdisk ' + pad(ramdiskSize) + ' B, ramdisk@0x' + oldRamdiskStart.toString(16));
console.log('new     : kernel ' + pad(newKernelSize) + ' B, ramdisk ' + pad(ramdiskSize) + ' B, ramdisk@0x' + newRamdiskStart.toString(16));
console.log('output  : ' + outPath + ' (' + out.length + ' bytes, header v' + headerVersion + ')');
