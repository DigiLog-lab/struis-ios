// Display selected SDK events; never change the messages consumed by Claude.
const SENSITIVE = /TOKEN|PASSWORD|SECRET|PRIVATE_KEY|API_KEY|APP_KEY|CERTIFICATE|PROVISION_PROFILE/i;

function redact(text, environment = process.env) {
  text = String(text).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');
  const secrets = Object.entries(environment).filter(([key]) => SENSITIVE.test(key))
    .flatMap(([, value]) => [value, ...String(value).split(/\r?\n/)].filter(v => v && v.length >= 6))
    .flatMap(value => [value, encodeURIComponent(value), JSON.stringify(value).slice(1, -1)])
    .sort((a, b) => b.length - a.length);
  for (const value of secrets) text = text.split(value).join('[REDACTED]');
  return text
    .replace(/-----BEGIN [^-]*(?:PRIVATE KEY|CERTIFICATE)-----[\s\S]*?-----END [^-]+-----/g, '[REDACTED PEM]')
    .replace(/(?:sk-(?:ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})/g, '[REDACTED TOKEN]')
    .replace(/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, '[REDACTED JWT]')
    .replace(/((?:authorization["']?\s*[:=]\s*["']?)(?:Bearer |Basic )?)[^\s"']+/gi, '$1[REDACTED]')
    .replace(/([\w.-]*(?:token|password|secret|api[_-]?key|private[_-]?key|app[_-]?key)[\w.-]*["']?\s*[:=]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,}]+)/gi, '$1[REDACTED]');
}

function resultText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.filter(b => b.type === 'text').map(b => b.text || '').join('\n');
  return '';
}

function formatLiveMessage(message, environment = process.env) {
  const lines = [];
  const blocks = message.message?.content;
  if (!Array.isArray(blocks)) return null;
  for (const block of blocks) {
    if (message.type === 'assistant' && block.type === 'text') {
      lines.push(`説明: ${block.text || ''}`);
    } else if (message.type === 'assistant' && block.type === 'tool_use') {
      lines.push(`ツール ${block.name} (${block.id}):\n${JSON.stringify(block.input, null, 2)}`);
    } else if (message.type === 'user' && block.type === 'tool_result') {
      lines.push(`ツール結果 ${block.tool_use_id}${block.is_error ? ' [失敗]' : ''}:\n${resultText(block.content)}`);
    }
  }
  if (!lines.length) return null;
  // Redact the entire event before truncation so multiline secrets stay hidden.
  let text = redact(lines.join('\n'), environment);
  if (text.length > 24000) text = text.slice(0, 12000) + '\n[長い出力の中間を省略]\n' + text.slice(-12000);
  // Prefix every line so tool output cannot become an Actions workflow command.
  return text.split('\n').map(line => `[Claude] ${line}`).join('\n');
}

module.exports = {redact, formatLiveMessage};
