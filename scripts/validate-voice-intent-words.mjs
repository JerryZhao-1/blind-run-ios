#!/usr/bin/env node

// 确认轮词表对撞：前端的本地直通表 vs 后端 `VoiceSlotParser` 的 `INTENT_*` 确定性兜底。
//
// 存在理由：读回之后用户说的那一句由**两处**判定 —— 本地整串表（零延迟直通，离线可用）和后端
// `userIntent`（大模型 + 正则兜底）。这个双层设计成立的唯一前提是「本地判出来的结论后端也会
// 判成同一个」；一旦某个本地词被后端判成**别的**意图，同一句话在有网/断网时的行为就分叉了。
//
// 这不是假想。2026-08-10 逐词对撞时抓到的第一个真冲突就是「再说一次」：
//
//   · 前端 `restartWords` 判「重说」→ 把用户刚说完的一整句**清空**
//   · 后端 `INTENT_REPEAT` 判「重播」→ 只是再念一遍读回
//
// 两者代价差着一整句话，而这句正是盲人没听清读回时最自然的说法。光看代码看不出来 ——
// 两份表在两个仓库、两种语言里，谁也不会顺手比一遍。所以比对交给机器。
//
// 判定规则（刻意不是「严格子集」）：
//   · **硬失败**：本地词被后端判成**另一个**意图。这是行为分叉，必须红。
//   · **只列出**：后端返回 empty（正则兜底不认，交给大模型）的本地词。本地是超集不会造成分歧 ——
//     本地先命中就不发网络，发了网络也是大模型说了算。列出来是给后端补正则的清单。
//
// 刻意不在本仓库存一份后端词表副本（AGENTS.md 第 7 节）：两份会漂移，而漂移正是本脚本要防的。
//
// 用法：
//   node scripts/validate-voice-intent-words.mjs [VoiceSlotParser.java 路径]
//   AIDRUN_BACKEND_VOICE_PARSER=/path/to/VoiceSlotParser.java node scripts/validate-voice-intent-words.mjs

import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(import.meta.dirname, '..');
// 可覆盖是为了能对着一份**故意造错**的副本跑一遍，证明这个门禁真的会红 ——
// 一个从没红过的守卫和没有守卫是一回事。
const swiftPath = path.resolve(
  repoRoot,
  process.env.AIDRUN_VOICE_WIZARD_SWIFT ?? 'blindRun/Voice/VoiceOrderWizard.swift'
);

const javaPath = path.resolve(
  repoRoot,
  process.argv[2] ??
    process.env.AIDRUN_BACKEND_VOICE_PARSER ??
    '../demo/src/main/java/com/example/demo/util/VoiceSlotParser.java'
);

if (!fs.existsSync(javaPath)) {
  console.error(`[voice-intent] 读不到后端意图解析器：${javaPath}`);
  console.error('[voice-intent] 这不算通过 —— 契约源在后端仓库，用 --add-dir 挂载或传路径参数。');
  process.exit(1);
}

// 序数那一族在另一个类里：播报文案由 `VoiceOrderService` 拼，`VoiceSlotParser` 不管它。
const servicePath = path.resolve(
  path.dirname(javaPath),
  process.env.AIDRUN_BACKEND_VOICE_SERVICE ?? '../service/VoiceOrderService.java'
);

// ---------------------------------------------------------------- 后端

// `private static final Pattern INTENT_CONFIRM = Pattern.compile("…" + "…");`
// 正则字面量可能被 `+` 拆成多段（后端为了可读性这么写的），拼回一整条。
function backendPattern(name) {
  const java = fs.readFileSync(javaPath, 'utf8');
  const decl = java.match(
    new RegExp(`Pattern\\s+${name}\\s*=\\s*(?:\\r?\\n\\s*)?Pattern\\.compile\\(([\\s\\S]*?)\\);`)
  );
  if (!decl) return null;
  const literals = [...decl[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]);
  if (!literals.length) return null;
  // Java 字符串里的 `\\d` 在正则里是 `\d`；这里的模式只用到 `\\s` 与 `\\.`，统一去掉一层转义。
  const source = literals.join('').replace(/\\\\/g, '\\');
  return new RegExp(source);
}

// 顺序即后端 `parseUserIntent` 的判定顺序（`VoiceSlotParser.java` 的 `parseUserIntent`），
// **不许调换**：REPEAT 排在 RESTART 之后（「重新说一遍」两条都命中，而它是 RESTART）；
// NOT_CONFIRM 排在 CONFIRM 之前（「不对」含「对」）。
const BACKEND_ORDER = [
  ['INTENT_CANCEL', 'CANCEL'],
  ['INTENT_RESTART', 'RESTART'],
  ['INTENT_REPEAT', 'REPEAT'],
  // 命中即「没有表态」，交给 correctionTarget / correctionUnclear 那条路。
  ['INTENT_NOT_CONFIRM', 'NONE'],
  ['INTENT_CONFIRM', 'CONFIRM'],
];

const patterns = BACKEND_ORDER.map(([name, intent]) => {
  const pattern = backendPattern(name);
  if (!pattern) {
    console.error(`[voice-intent] 在 ${javaPath} 里找不到 ${name}，后端的写法可能变了。`);
    process.exit(1);
  }
  return { name, intent, pattern };
});

/** 后端会把这句话判成什么。`NONE` = 正则兜底不认，交给大模型。 */
function backendIntent(word) {
  for (const { intent, pattern } of patterns) {
    if (pattern.test(word)) return intent;
  }
  return 'NONE';
}

// ---------------------------------------------------------------- 前端

const swift = fs.readFileSync(swiftPath, 'utf8');

function swiftWords(declaration) {
  const body = swift.match(new RegExp(`${declaration}[^=]*=\\s*\\[([\\s\\S]*?)\\]`));
  if (!body) return null;
  return [...body[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

// 前端本地表 → 它声称的意图。三张表都在 `VoiceOrderWizard` 的「Command recognition」一节。
const FRONTEND_TABLES = [
  ['affirmatives', 'CONFIRM'],
  ['restartWords', 'RESTART'],
  ['repeatWords', 'REPEAT'],
];

const tables = FRONTEND_TABLES.map(([name, intent]) => {
  const words = swiftWords(`let ${name}`);
  if (!words?.length) {
    console.error(`[voice-intent] 在 ${swiftPath} 里解不出 ${name}，格式可能变了。`);
    process.exit(1);
  }
  return { name, intent, words };
});

// ---------------------------------------------------------------- 对撞

const conflicts = [];
const backendUnaware = [];

for (const { name, intent, words } of tables) {
  for (const word of words) {
    const actual = backendIntent(word);
    if (actual === intent) continue;
    if (actual === 'NONE') {
      backendUnaware.push({ table: name, word, claimed: intent });
    } else {
      conflicts.push({ table: name, word, claimed: intent, actual });
    }
  }
}

// ------------------------------------------------- 序数：方向与上面三张表相反
//
// 上面查的是「本地认的词，后端会不会判成别的」；这里查的是「**后端念给用户的词，本地认不认得**」。
// 方向反过来是因为**教用户说什么由后端决定** —— 候选消歧那一轮播的是后端的 `ttsText`
// （「找到3个地点，请说第几个。第一个，…」），而用户的回答由客户端本地匹配。
// 系统念一个词、本地认另一个，盲人照着念却不生效，而屏幕上没有任何东西能让他发现。
//
// 所以这一条是**覆盖检查**，不是子集检查：后端 ORDINALS 里的每一个都必须能被本地认出来。
// 本地多认几种写法（阿拉伯数字）是好事，不报。
const ordinalProblems = [];
if (!fs.existsSync(servicePath)) {
  console.error(`[voice-intent] 读不到后端播报文案来源：${servicePath}`);
  console.error('[voice-intent] 这不算通过 —— 序数是后端念给用户听的词，必须拿它的定义来对。');
  process.exit(1);
}
const ordinalsDecl = fs
  .readFileSync(servicePath, 'utf8')
  .match(/String\[\]\s+ORDINALS\s*=\s*\{([^}]*)\}/);
if (!ordinalsDecl) {
  console.error(`[voice-intent] 在 ${servicePath} 里找不到 ORDINALS，后端的写法可能变了。`);
  process.exit(1);
}
const backendOrdinals = [...ordinalsDecl[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);

// 前端：`ordinalForms` 是 `[[String]]`，逐行一组，下标即候选下标。
const formsBlock = swift.match(/let ordinalForms:\s*\[\[String\]\]\s*=\s*\[([\s\S]*?)\n\s*\]/);
if (!formsBlock) {
  console.error(`[voice-intent] 在 ${swiftPath} 里解不出 ordinalForms，格式可能变了。`);
  process.exit(1);
}
const frontendOrdinalForms = [...formsBlock[1].matchAll(/\[([^\]]*)\]/g)].map((row) =>
  [...row[1].matchAll(/"([^"]+)"/g)].map((m) => m[1])
);

if (!backendOrdinals.length || !frontendOrdinalForms.length) {
  console.error(
    `[voice-intent] 序数解析异常：后端 ${backendOrdinals.length} 个、前端 ${frontendOrdinalForms.length} 组。`
  );
  process.exit(1);
}

backendOrdinals.forEach((spoken, index) => {
  const forms = frontendOrdinalForms[index];
  if (!forms) {
    ordinalProblems.push(`后端念第 ${index + 1} 个候选用「${spoken}」，前端 ordinalForms 没有这一组`);
    return;
  }
  // 前端 `ordinalIndex` 用的是包含匹配，这里照同一套判：本地任一写法是后端那句的子串即可。
  if (!forms.some((form) => spoken.includes(form))) {
    ordinalProblems.push(
      `后端念「${spoken}」（第 ${index + 1} 个），而前端第 ${index + 1} 组只认 ${forms
        .map((f) => `「${f}」`)
        .join('、')}`
    );
  }
});

const total = tables.reduce((n, t) => n + t.words.length, 0);
console.log(
  `[voice-intent] 前端本地直通表 ${total} 个词（${tables
    .map((t) => `${t.name} ${t.words.length}`)
    .join('、')}），逐词过了后端 5 条正则；` +
    `序数 ${backendOrdinals.length} 个（${backendOrdinals.join('/')}）逐个查了本地能不能认出来。`
);

if (backendUnaware.length) {
  console.log(
    `\n[voice-intent] · 后端确定性兜底不认的本地词（${backendUnaware.length} 个，不计入失败）：`
  );
  for (const { table, word } of backendUnaware) console.log(`  · ${word}（前端 ${table}）`);
  console.log(
    '  这些词本地先命中就不发网络，所以不会造成行为分歧；发了网络则以后端大模型为准。\n' +
      '  但其中若有**读回亲口教用户说的词**，值得请后端补进正则兜底 —— 模型不可用时那个词就失效了。'
  );
}

if (conflicts.length) {
  console.error(`\n[voice-intent] ✗ 本地表与后端判定分叉（${conflicts.length} 处）：`);
  for (const { table, word, claimed, actual } of conflicts) {
    console.error(`  · 「${word}」前端 ${table} 判 ${claimed}，后端判 ${actual}`);
  }
  console.error(
    '\n同一句话在有网和断网时会走两条不同的路 —— 而这两条路的代价往往不对称' +
      '\n（把 REPEAT 当成 RESTART 会清空用户刚说完的一整句）。' +
      '\n以代价小的那一边为准改前端表，或者请后端改正则，两者选一，不能就这么放着。' +
      `\n后端源：${javaPath}`
  );
}

if (ordinalProblems.length) {
  console.error(`\n[voice-intent] ✗ 后端念的序数本地认不出来（${ordinalProblems.length} 处）：`);
  for (const problem of ordinalProblems) console.error(`  · ${problem}`);
  console.error(
    '\n候选消歧那一轮播的是后端的 ttsText，而用户的回答由客户端本地匹配 ——' +
      '\n系统念一个词、本地认另一个，盲人照着念却不生效，屏幕上没有任何东西能让他发现。' +
      '\n改前端 `ordinalForms` 跟上后端，别反过来让后端迁就前端：教用户说什么由播报那一方定。' +
      `\n后端源：${servicePath}`
  );
}

if (conflicts.length || ordinalProblems.length) {
  process.exit(1);
}

console.log(
  '\n[voice-intent] 通过：本地直通表没有一个词会被后端判成别的意图，' +
    '后端念的每个序数本地也都认得'
);
