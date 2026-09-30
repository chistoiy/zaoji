// R46 · 快赢包：把 kEndpoints 尾部（AI 代理 + R44 记录/提示词 + /status）重排成规整字面量。
// 护栏：改前快照、命中断言（首尾标记各恰好一次）、体积校验。
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '../server/lib/src/server_state.dart');
const src = fs.readFileSync(file, 'utf8');

const snap = path.resolve(__dirname, '../dist/server_state_before_r46endpoints.dart');
fs.writeFileSync(snap, src);

const START = "/// 大模型代理：热量估算。";
const END = "  'title': 'AI 执行记录：清空',\n  'status': 'ready'\n},\n];";
const i = src.indexOf(START);
const j = src.indexOf(END);
const hits = (s) => src.split(s).length - 1;
if (i < 0 || j < 0) throw new Error('锚点未命中：START=' + i + ' END=' + j);
if (hits(START) !== 1) throw new Error('START 命中 ' + hits(START) + ' 次，应为 1');
if (hits(END) !== 1) throw new Error('END 命中 ' + hits(END) + ' 次，应为 1');
if (j < i) throw new Error('锚点顺序不对');

function e(method, p, title) {
  return `  {\n    'path': ${JSON.stringify(p)},\n    'method': ${JSON.stringify(method)},\n` +
    `    'title': ${JSON.stringify(title)},\n    'status': 'ready'\n  },`;
}

const block = [
  "  {\n    'path': '/status',\n    'method': 'GET',\n    'title': '服务状态页（服务端本机地址：管理后台）',\n    'status': 'ready'\n  },",
  e('POST', '/api/ai/calories', '大模型代理：按食材与步骤估算热量'),
  e('POST', '/api/ai/recommend', '大模型代理：按现有库存推荐菜谱'),
  e('POST', '/api/ai/recipe-fill', '大模型代理：把菜名补全成草稿'),
  e('GET', '/api/ai/prompts', 'AI 提示词：逐能力查看（含默认模板）'),
  e('POST', '/api/ai/prompts', 'AI 提示词：保存自定义模板'),
  e('POST', '/api/ai/prompts/reset', 'AI 提示词：恢复某能力的默认模板'),
  e('GET', '/api/ai/runs', 'AI 执行记录：分页列表（可按能力/成败筛）'),
  e('GET', '/api/ai/runs/{id}', 'AI 执行记录：单条详情（含提示词与回复）'),
  e('DELETE', '/api/ai/runs/{id}', 'AI 执行记录：删一条'),
  e('DELETE', '/api/ai/runs', 'AI 执行记录：清空（只清本机可见的）'),
  '];'
].join('\n');

const out = src.slice(0, i) + block + src.slice(j + END.length);
if (out.length < src.length * 0.9) throw new Error('体积异常：' + src.length + ' -> ' + out.length);
fs.writeFileSync(file, out);
console.log('✔ 重写完成 ' + src.length + ' -> ' + out.length + '，快照 ' + snap);
