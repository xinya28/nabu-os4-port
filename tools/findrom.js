#!/usr/bin/env node
// 从 XiaomiFirmwareUpdater 的 tracker 里解析出"某个机型最新的澎湃OS 固件直链"。
//
//   node tools/findrom.js --device yupei                 # Pad 8/9 中国版，默认取 Recovery(OTA) 包
//   node tools/findrom.js --device uke --method Fastboot
//   node tools/findrom.js --check --device yupei         # 顺带 HEAD 一下，确认链接活着
//   node tools/findrom.js --json --device piano
//   node tools/findrom.js --list                        # 列出所有有 OS4 条目的平板
//
// 为什么要有这个脚本：小米 CDN 直链带版本号、会随新版本变化，写死在仓库里必然过期；
// 而"打开浏览器去论坛翻链接"又不是可复现的步骤。tracker 是社区维护的机器可读索引，
// 这里把它变成一个参数。
//
// --method 的选择（对移植有实际影响）：
//   Recovery = OTA zip，内含 payload.bin，逐逻辑分区，02_unpack 可直接解（首选）
//   Fastboot = tgz，内含 super.img，需要 lpunpack 才能拆（体积也更大）
//
// 无第三方依赖；需要代理时设 HTTPS_PROXY 或 --proxy 127.0.0.1:7897。
"use strict";
const fs = require("fs");
const net = require("net");
const tls = require("tls");
const https = require("https");

const TRACKER =
  "https://raw.githubusercontent.com/XiaomiFirmwareUpdater/miui-updates-tracker/master/data/latest.yml";
const CACHE = process.env.FINDROM_CACHE || "";

function arg(name, def) {
  const i = process.argv.indexOf("--" + name);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v && !v.startsWith("--") ? v : true;
}

function proxyConfig() {
  const explicit = arg("proxy", null);
  let host = null;
  let port = null;
  if (typeof explicit === "string") {
    [host, port] = explicit.split(":");
  } else if (process.env.HTTPS_PROXY || process.env.https_proxy) {
    const u = new URL(process.env.HTTPS_PROXY || process.env.https_proxy);
    host = u.hostname;
    port = u.port || "7897";
  } else if (process.env.DSH_PROXY_PORT) {
    host = "127.0.0.1";
    port = process.env.DSH_PROXY_PORT;
  }
  return host ? { host, port: Number(port) } : null;
}

function tunnel(proxy, host, port) {
  return new Promise((resolve, reject) => {
    const s = net.connect(proxy.port, proxy.host, () => {
      s.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`);
    });
    let buf = "";
    const onData = (d) => {
      buf += d.toString("latin1");
      const i = buf.indexOf("\r\n\r\n");
      if (i < 0) return;
      s.removeListener("data", onData);
      if (!/^HTTP\/1\.[01] 200/.test(buf.slice(0, i))) {
        s.destroy();
        return reject(new Error("proxy CONNECT refused: " + buf.slice(0, i).split("\r\n")[0]));
      }
      resolve(s);
    };
    s.on("data", onData);
    s.on("error", reject);
  });
}

function request(method, urlStr, opts = {}) {
  const u = new URL(urlStr);
  const proxy = proxyConfig();
  return (async () => {
    const sock = proxy ? await tunnel(proxy, u.hostname, u.port || 443) : undefined;
    return new Promise((resolve, reject) => {
      const req = https.request(
        {
          host: u.hostname,
          port: u.port || 443,
          path: u.pathname + u.search,
          method,
          headers: opts.headers || {},
          ...(sock
            ? { createConnection: () => tls.connect({ socket: sock, servername: u.hostname }) }
            : {}),
        },
        (res) => {
          if (opts.headOnly) {
            res.resume();
            return resolve({ status: res.statusCode, headers: res.headers, body: "" });
          }
          const chunks = [];
          res.on("data", (c) => chunks.push(c));
          res.on("end", () =>
            resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) })
          );
        }
      );
      req.on("error", reject);
      req.setTimeout(120000, () => req.destroy(new Error("timeout")));
      req.end();
    });
  })();
}

// latest.yml 是 "- android: ... / branch: ..." 这种扁平块序列，没有嵌套，逐行扫即可
function parseLatest(text) {
  const recs = [];
  let cur = null;
  const put = (k, v) => {
    if (cur && k) cur[k] = v.replace(/^['"]|['"]$/g, "");
  };
  for (const line of text.split(/\r?\n/)) {
    if (/^-\s/.test(line)) {
      if (cur) recs.push(cur);
      cur = {};
      const m = line.match(/^-\s+(\w+):\s*(.*)$/);
      if (m) put(m[1], m[2]);
      continue;
    }
    const m = line.match(/^\s{2}(\w+):\s*(.*)$/);
    if (m) put(m[1], m[2]);
  }
  if (cur) recs.push(cur);
  return recs;
}

async function loadTracker() {
  if (CACHE && fs.existsSync(CACHE)) {
    return fs.readFileSync(CACHE, "utf8");
  }
  process.stderr.write(`findrom: 拉取 tracker（${proxyConfig() ? "经代理" : "直连"}）…\n`);
  const r = await request("GET", TRACKER, { headers: { "User-Agent": "nabu-os4-port" } });
  if (r.status !== 200) throw new Error(`tracker HTTP ${r.status}`);
  const text = r.body.toString("utf8");
  if (CACHE) fs.writeFileSync(CACHE, text, "utf8");
  return text;
}

function human(bytes) {
  const gb = bytes / 1024 ** 3;
  return gb >= 1 ? gb.toFixed(1) + " GiB" : (bytes / 1024 ** 2).toFixed(0) + " MiB";
}

(async () => {
  const text = await loadTracker();
  const recs = parseLatest(text);

  // 只要平板（按 codename 白名单 + Android 17 = OS4 双重过滤，避免把手机混进来）
  const TABLETS = {
    yupei: "Xiaomi Pad 8 / Pad 9",
    piano: "Xiaomi Pad 8 Pro",
    uke: "Xiaomi Pad 7",
    muyu: "Xiaomi Pad 7 Pro",
    jinghu: "Xiaomi Pad 7 Ultra",
    violin: "Xiaomi Pad 7S Pro 12.5",
    sheng: "Xiaomi Pad 6S Pro 12.4",
    yili: "REDMI K Pad 2",
    yingtian: "Xiaomi Pad 9 Pro Max",
  };

  if (arg("list")) {
    const seen = new Map();
    for (const r of recs) {
      if (!TABLETS[r.codename]) continue;
      if (!String(r.android || "").startsWith("17")) continue;
      const key = r.codename + "|" + r.method;
      if (!seen.has(key)) seen.set(key, r);
    }
    for (const r of seen.values()) {
      console.log(
        [r.codename, TABLETS[r.codename], r.version, r.method, r.size, r.date].join(" | ")
      );
    }
    return;
  }

  const device = arg("device", null);
  if (!device || typeof device !== "string") {
    console.error("用法: node tools/findrom.js --device <codename> [--method Recovery|Fastboot]");
    console.error("      node tools/findrom.js --list");
    process.exit(2);
  }
  const method = arg("method", "Recovery");

  const cands = recs
    .filter((r) => r.codename === device)
    .filter((r) => (method === "any" ? true : r.method === method))
    .filter((r) => String(r.android || "").startsWith("17"));
  if (!cands.length) {
    console.error(
      `findrom: ${device} 没有 android 17（OS4）且 method=${method} 的条目。` +
        `\n  用 --method any 看看有没有其它打包方式，或 --list 看哪些机型有 OS4。`
    );
    process.exit(1);
  }
  // 取日期最新的
  cands.sort((a, b) => String(b.date).localeCompare(String(a.date)));
  const picked = cands[0];

  let head = null;
  let finalUrl = picked.link;

  // 小米的 OTA 直链在不同 CDN 域名上是同一份文件，但可用性差别很大：
  // 实测（2026-11）bigota / hugeota 返回 403（kngx），cdnorg 正常 206。
  // 所以默认把 d.miui.com 的链接改写到 cdnorg，并用 Range GET 实测确认。
  const onlyMiui = (u) => new URL(u).hostname.endsWith("d.miui.com");
  const HOSTS = String(
    arg("hosts", "cdnorg.d.miui.com,bigota.d.miui.com,hugeota.d.miui.com")
  )
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const rewrite = (u, host) => {
    const x = new URL(u);
    x.host = host;
    return x.toString();
  };

  const probe = async (u) =>
    request("GET", u, {
      headOnly: true,
      headers: {
        Range: "bytes=0-0",
        "User-Agent":
          "Mozilla/5.0 (Linux; Android 14; Tablet) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
      },
    });

  if (arg("check", false)) {
    process.stderr.write("findrom: 校验链接（Range GET bytes=0-0）…\n");
    const cands = onlyMiui(picked.link)
      ? [...HOSTS.map((h) => rewrite(picked.link, h)), picked.link]
      : [picked.link];
    const tried = [];
    for (const u of cands) {
      try {
        const r = await probe(u);
        tried.push(`${new URL(u).hostname}=${r.status}`);
        if (r.status === 200 || r.status === 206) {
          head = r;
          finalUrl = u;
          break;
        }
      } catch (e) {
        tried.push(`${new URL(u).hostname}=ERR(${e.message})`);
      }
    }
    if (!head) process.stderr.write(`findrom: 所有镜像都不可用：${tried.join(", ")}\n`);
    else process.stderr.write(`findrom: 可用镜像 ${new URL(finalUrl).hostname}（${tried.join(", ")}）\n`);
  } else if (onlyMiui(picked.link)) {
    finalUrl = rewrite(picked.link, HOSTS[0]);
  }

  const totalBytes = (() => {
    if (!head || !head.headers) return 0;
    const cr = head.headers["content-range"] || "";
    const m = cr.match(/\/(\d+)\s*$/);
    if (m) return Number(m[1]);
    return Number(head.headers["content-length"] || 0);
  })();

  if (arg("json", false)) {
    console.log(
      JSON.stringify(
        {
          codename: picked.codename,
          name: picked.name,
          version: picked.version,
          android: picked.android,
          branch: picked.branch,
          method: picked.method,
          date: picked.date,
          size: picked.size,
          md5: picked.md5,
          url: finalUrl,
          mirror: new URL(finalUrl).hostname,
          head_status: head ? head.status : null,
          head_bytes: totalBytes,
        },
        null,
        2
      )
    );
    return;
  }

  console.log(finalUrl);
  if (head) {
    console.error(`check ${head.status}` + (totalBytes ? `  ${human(totalBytes)}` : "") + `  ${new URL(finalUrl).hostname}`);
  }
})().catch((e) => {
  console.error("findrom: " + e.message);
  process.exit(1);
});
