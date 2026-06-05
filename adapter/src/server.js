const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { URL } = require("node:url");

const rootDir = path.resolve(__dirname, "..");
const dataDir = path.join(rootDir, "data");
const keyPath = path.join(dataDir, "adapter-api-key.txt");
const logPath = path.join(dataDir, "requests.log");

loadDotEnv(path.join(rootDir, ".env"));
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

const config = {
  host: process.env.HOST || "127.0.0.1",
  port: Number(process.env.PORT || 8791),
  upstreamBaseUrl: trimSlash(process.env.UPSTREAM_BASE_URL || ""),
  upstreamApiKey: process.env.UPSTREAM_API_KEY || "",
  defaultModel: process.env.DEFAULT_MODEL || "ag/claude-opus-4-6-thinking",
  opusModel: process.env.OPUS_MODEL || "ag/claude-opus-4-6-thinking",
  sonnetModel: process.env.SONNET_MODEL || "ag/claude-sonnet-4-6",
  haikuModel: process.env.HAIKU_MODEL || "ag/claude-sonnet-4-6",
  timeoutMs: Number(process.env.REQUEST_TIMEOUT_SECONDS || 300) * 1000,
  maxBodyBytes: Number(process.env.MAX_BODY_BYTES || 10 * 1024 * 1024)
};

const adapterApiKey = getAdapterApiKey();

const server = http.createServer((req, res) => {
  route(req, res).catch((error) => {
    appendLog({ at: new Date().toISOString(), level: "error", message: error.message });
    sendJson(res, 500, {
      error: {
        type: "server_error",
        message: "Erro interno no adaptador."
      }
    });
  });
});

server.listen(config.port, config.host, () => {
  console.log(`ABC Claude Adapter: http://${config.host}:${config.port}`);
  console.log(`Adapter API key: ${keyPath}`);
});

async function route(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);

  if (req.method === "GET" && url.pathname === "/health") {
    return sendJson(res, 200, {
      ok: true,
      upstreamBaseUrl: config.upstreamBaseUrl,
      upstreamConfigured: Boolean(config.upstreamBaseUrl && config.upstreamApiKey),
      defaultModel: config.defaultModel,
      opusModel: config.opusModel,
      sonnetModel: config.sonnetModel,
      haikuModel: config.haikuModel
    });
  }

  if (url.pathname === "/v1/models" && req.method === "GET") {
    if (!isAuthorized(req)) return unauthorized(res);
    return handleModels(res);
  }

  if (url.pathname === "/v1/messages" && req.method === "POST") {
    if (!isAuthorized(req)) return unauthorized(res);
    return handleMessages(req, res);
  }

  sendJson(res, 404, {
    error: {
      type: "not_found",
      message: "Rota nao encontrada."
    }
  });
}

async function handleModels(res) {
  const upstream = await fetchWithTimeout(`${config.upstreamBaseUrl}/models`, {
    headers: {
      authorization: `Bearer ${config.upstreamApiKey}`
    }
  });
  const text = await upstream.text();
  if (!upstream.ok) {
    return sendJson(res, upstream.status, {
      error: {
        type: "upstream_error",
        message: redact(text).slice(0, 1000)
      }
    });
  }

  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { data: [] };
  }

  sendJson(res, 200, {
    object: "list",
    data: (parsed.data || []).map((model) => ({
      id: model.id,
      type: "model",
      display_name: model.id
    }))
  });
}

async function handleMessages(req, res) {
  const started = Date.now();
  const rawBody = await readRawBody(req, config.maxBodyBytes);
  let body;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return sendJson(res, 400, {
      error: {
        type: "invalid_request_error",
        message: "JSON invalido."
      }
    });
  }

  const model = normalizeModel(body.model);
  const openAiTools = toOpenAiTools(body.tools);
  const usesTools = openAiTools.length > 0;
  const wantsStream = body.stream === true;
  const openAiBody = {
    model,
    messages: toOpenAiMessages(body),
    max_tokens: body.max_tokens || body.max_completion_tokens || 1024,
    temperature: typeof body.temperature === "number" ? body.temperature : undefined,
    top_p: typeof body.top_p === "number" ? body.top_p : undefined,
    stop: Array.isArray(body.stop_sequences) && body.stop_sequences.length ? body.stop_sequences : undefined,
    stream: !usesTools
  };

  if (usesTools) {
    openAiBody.tools = openAiTools;
    openAiBody.tool_choice = toOpenAiToolChoice(body.tool_choice);
  }

  const upstream = await fetchWithTimeout(`${config.upstreamBaseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${config.upstreamApiKey}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(openAiBody)
  });

  if (!upstream.ok) {
    const errorText = await upstream.text();
    appendLog({ at: new Date().toISOString(), model, status: upstream.status, error: redact(errorText).slice(0, 500) });
    return sendJson(res, upstream.status, {
      error: {
        type: "upstream_error",
        message: redact(errorText).slice(0, 1000)
      }
    });
  }

  if (wantsStream && !usesTools) {
    return streamAnthropicFromOpenAi(req, res, upstream, model, started);
  }

  const openAiText = await upstream.text();
  const result = parseOpenAiMessage(openAiText);
  appendLog({
    at: new Date().toISOString(),
    model,
    status: 200,
    latencyMs: Date.now() - started,
    stream: wantsStream,
    outputChars: result.text.length,
    toolCalls: result.toolCalls.length
  });

  if (wantsStream) {
    return streamAnthropicResult(res, model, result, body);
  }

  sendJson(res, 200, anthropicMessage(model, result, body));
}

async function streamAnthropicFromOpenAi(req, res, upstream, model, started) {
  const messageId = `msg_${crypto.randomBytes(12).toString("hex")}`;
  let outputText = "";

  res.statusCode = 200;
  res.setHeader("content-type", "text/event-stream; charset=utf-8");
  res.setHeader("cache-control", "no-cache");

  writeSse(res, "message_start", {
    type: "message_start",
    message: {
      id: messageId,
      type: "message",
      role: "assistant",
      model,
      content: [],
      stop_reason: null,
      stop_sequence: null,
      usage: { input_tokens: 1, output_tokens: 0 }
    }
  });
  writeSse(res, "content_block_start", {
    type: "content_block_start",
    index: 0,
    content_block: { type: "text", text: "" }
  });

  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of upstream.body) {
    buffer += decoder.decode(chunk, { stream: true });
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data:")) continue;
      const data = trimmed.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      let parsed;
      try {
        parsed = JSON.parse(data);
      } catch {
        continue;
      }
      const delta = parsed.choices?.[0]?.delta?.content || parsed.choices?.[0]?.message?.content || "";
      if (!delta) continue;
      outputText += delta;
      writeSse(res, "content_block_delta", {
        type: "content_block_delta",
        index: 0,
        delta: { type: "text_delta", text: delta }
      });
    }
  }

  writeSse(res, "content_block_stop", { type: "content_block_stop", index: 0 });
  writeSse(res, "message_delta", {
    type: "message_delta",
    delta: { stop_reason: "end_turn", stop_sequence: null },
    usage: { output_tokens: estimateTokens(outputText) }
  });
  writeSse(res, "message_stop", { type: "message_stop" });
  res.end();

  appendLog({ at: new Date().toISOString(), model, status: 200, latencyMs: Date.now() - started, stream: true, outputChars: outputText.length });
}

function streamAnthropicResult(res, model, result, body) {
  const messageId = `msg_${crypto.randomBytes(12).toString("hex")}`;
  let index = 0;

  res.statusCode = 200;
  res.setHeader("content-type", "text/event-stream; charset=utf-8");
  res.setHeader("cache-control", "no-cache");

  writeSse(res, "message_start", {
    type: "message_start",
    message: {
      id: messageId,
      type: "message",
      role: "assistant",
      model,
      content: [],
      stop_reason: null,
      stop_sequence: null,
      usage: usageFromOpenAiResult(result, body)
    }
  });

  if (result.text) {
    writeSse(res, "content_block_start", {
      type: "content_block_start",
      index,
      content_block: { type: "text", text: "" }
    });
    writeSse(res, "content_block_delta", {
      type: "content_block_delta",
      index,
      delta: { type: "text_delta", text: result.text }
    });
    writeSse(res, "content_block_stop", { type: "content_block_stop", index });
    index += 1;
  }

  for (const toolCall of result.toolCalls) {
    const inputJson = JSON.stringify(toolCall.input || {});
    writeSse(res, "content_block_start", {
      type: "content_block_start",
      index,
      content_block: {
        type: "tool_use",
        id: toolCall.id,
        name: toolCall.name,
        input: {}
      }
    });
    if (inputJson !== "{}") {
      writeSse(res, "content_block_delta", {
        type: "content_block_delta",
        index,
        delta: { type: "input_json_delta", partial_json: inputJson }
      });
    }
    writeSse(res, "content_block_stop", { type: "content_block_stop", index });
    index += 1;
  }

  if (index === 0) {
    writeSse(res, "content_block_start", {
      type: "content_block_start",
      index,
      content_block: { type: "text", text: "" }
    });
    writeSse(res, "content_block_stop", { type: "content_block_stop", index });
  }

  writeSse(res, "message_delta", {
    type: "message_delta",
    delta: { stop_reason: stopReasonFromOpenAiResult(result), stop_sequence: null },
    usage: { output_tokens: usageFromOpenAiResult(result, body).output_tokens }
  });
  writeSse(res, "message_stop", { type: "message_stop" });
  res.end();
}

function anthropicMessage(model, result, body) {
  if (typeof result === "string") result = { text: result, toolCalls: [], finishReason: "stop", usage: null };
  const content = [];
  if (result.text) content.push({ type: "text", text: result.text });
  for (const toolCall of result.toolCalls || []) {
    content.push({
      type: "tool_use",
      id: toolCall.id,
      name: toolCall.name,
      input: toolCall.input || {}
    });
  }
  if (!content.length) content.push({ type: "text", text: "" });

  return {
    id: `msg_${crypto.randomBytes(12).toString("hex")}`,
    type: "message",
    role: "assistant",
    model,
    stop_reason: stopReasonFromOpenAiResult(result),
    stop_sequence: null,
    content,
    usage: usageFromOpenAiResult(result, body)
  };
}

function toOpenAiMessages(body) {
  const messages = [];
  const knownToolCallIds = new Set();

  if (body.system) {
    const systemText = Array.isArray(body.system)
      ? body.system.map(contentPartToText).filter(Boolean).join("\n")
      : String(body.system);
    if (systemText.trim()) messages.push({ role: "system", content: systemText });
  }

  for (const message of body.messages || []) {
    const role = message.role === "assistant" ? "assistant" : "user";
    const parts = Array.isArray(message.content)
      ? message.content
      : [{ type: "text", text: String(message.content || "") }];

    if (role === "assistant") {
      const text = parts.map(contentPartToText).filter(Boolean).join("\n");
      const toolCalls = parts
        .filter((part) => part && typeof part === "object" && part.type === "tool_use")
        .map((part) => anthropicToolUseToOpenAiToolCall(part));

      for (const toolCall of toolCalls) knownToolCallIds.add(toolCall.id);

      if (toolCalls.length) {
        messages.push({
          role: "assistant",
          content: text.trim() ? text : null,
          tool_calls: toolCalls
        });
      } else if (text.trim()) {
        messages.push({ role, content: text });
      }
      continue;
    }

    let pendingText = [];
    const flushPendingText = () => {
      const content = pendingText.filter(Boolean).join("\n");
      pendingText = [];
      if (content.trim()) messages.push({ role: "user", content });
    };

    for (const part of parts) {
      if (part && typeof part === "object" && part.type === "tool_result") {
        flushPendingText();
        const toolCallId = String(part.tool_use_id || part.id || "").trim();
        const content = toolResultToText(part);
        if (toolCallId && knownToolCallIds.has(toolCallId)) {
          messages.push({ role: "tool", tool_call_id: toolCallId, content });
        } else if (content.trim()) {
          messages.push({
            role: "user",
            content: `Resultado de ferramenta${toolCallId ? ` ${toolCallId}` : ""}:\n${content}`
          });
        }
        continue;
      }

      const content = contentPartToText(part);
      if (content.trim()) pendingText.push(content);
    }
    flushPendingText();
  }

  if (!messages.length) messages.push({ role: "user", content: "Responda OK." });
  return messages;
}

function contentPartToText(part) {
  if (typeof part === "string") return part;
  if (!part || typeof part !== "object") return "";
  if (part.type === "text") return String(part.text || "");
  if (part.type === "tool_result") return toolResultToText(part);
  if (part.type === "tool_use") return "";
  if (part.type === "image") return "[Imagem omitida pelo adaptador local.]";
  return JSON.stringify(part);
}

function toolResultToText(part) {
  const content = part && Object.prototype.hasOwnProperty.call(part, "content") ? part.content : part;
  let text;
  if (typeof content === "string") {
    text = content;
  } else if (Array.isArray(content)) {
    text = content.map(contentPartToText).filter(Boolean).join("\n");
  } else {
    text = JSON.stringify(content || "", null, 2);
  }

  if (part && part.is_error) return `Erro da ferramenta:\n${text}`;
  return text;
}

function anthropicToolUseToOpenAiToolCall(part) {
  const id = String(part.id || `toolu_${crypto.randomBytes(8).toString("hex")}`);
  const input = part.input && typeof part.input === "object" && !Array.isArray(part.input) ? part.input : {};
  return {
    id,
    type: "function",
    function: {
      name: String(part.name || "unknown_tool"),
      arguments: JSON.stringify(input)
    }
  };
}

function toOpenAiTools(tools) {
  if (!Array.isArray(tools)) return [];
  return tools
    .filter((tool) => tool && typeof tool === "object" && tool.name)
    .map((tool) => ({
      type: "function",
      function: {
        name: String(tool.name),
        description: String(tool.description || ""),
        parameters: tool.input_schema && typeof tool.input_schema === "object"
          ? tool.input_schema
          : { type: "object", properties: {} }
      }
    }));
}

function toOpenAiToolChoice(toolChoice) {
  if (!toolChoice) return "auto";
  if (typeof toolChoice === "string") return toolChoice;
  if (toolChoice.type === "none") return "none";
  if (toolChoice.type === "tool" && toolChoice.name) {
    return { type: "function", function: { name: String(toolChoice.name) } };
  }
  return "auto";
}

function normalizeModel(model) {
  const value = String(model || config.defaultModel).trim();
  const normalized = normalizeModelName(value);
  const map = {
    default: config.defaultModel,
    auto: "kr/auto",
    "auto-thinking": "kr/auto-thinking",
    haiku: config.haikuModel,
    opus: config.opusModel,
    sonnet: config.sonnetModel,
    "claude-3-haiku": config.haikuModel,
    "claude-3-5-haiku": config.haikuModel,
    "claude-haiku-4.5": config.haikuModel,
    "claude-haiku-4-5": config.haikuModel,
    "claude-haiku-4-5-20251001": config.haikuModel,
    "claude-haiku-4.5-thinking": "kr/claude-haiku-4.5-thinking",
    "claude-haiku-4-5-thinking": "kr/claude-haiku-4.5-thinking",
    "claude-haiku-4.5-agentic": "kr/claude-haiku-4.5-agentic",
    "claude-haiku-4-5-agentic": "kr/claude-haiku-4.5-agentic",
    "claude-haiku-4.5-thinking-agentic": "kr/claude-haiku-4.5-thinking-agentic",
    "claude-haiku-4-5-thinking-agentic": "kr/claude-haiku-4.5-thinking-agentic",
    "claude-sonnet-4.5": config.sonnetModel,
    "claude-sonnet-4-5": config.sonnetModel,
    "claude-sonnet-4": config.sonnetModel,
    "claude-sonnet-4-20250514": config.sonnetModel,
    "claude-sonnet-4-6": config.sonnetModel,
    "claude-sonnet-4-6-20251120": config.sonnetModel,
    "claude-sonnet-4.5-thinking": "kr/claude-sonnet-4.5-thinking",
    "claude-sonnet-4-5-thinking": "kr/claude-sonnet-4.5-thinking",
    "claude-sonnet-4.5-agentic": "kr/claude-sonnet-4.5-agentic",
    "claude-sonnet-4-5-agentic": "kr/claude-sonnet-4.5-agentic",
    "claude-sonnet-4.5-thinking-agentic": "kr/claude-sonnet-4.5-thinking-agentic",
    "claude-sonnet-4-5-thinking-agentic": "kr/claude-sonnet-4.5-thinking-agentic",
    "claude-opus-4.5": config.opusModel,
    "claude-opus-4-5": config.opusModel,
    "claude-opus-4.6": config.opusModel,
    "claude-opus-4-6": config.opusModel,
    "claude-opus-4.7": config.opusModel,
    "claude-opus-4-7": config.opusModel,
    "claude-opus-4.8": config.opusModel,
    "claude-opus-4-8": config.opusModel,
    "claude-opus-4.8-thinking": "kr/claude-opus-4.8-thinking",
    "claude-opus-4-8-thinking": "kr/claude-opus-4.8-thinking",
    "claude-opus-4.8-agentic": "kr/claude-opus-4.8-agentic",
    "claude-opus-4-8-agentic": "kr/claude-opus-4.8-agentic",
    "claude-opus-4.8-thinking-agentic": "kr/claude-opus-4.8-thinking-agentic",
    "claude-opus-4-8-thinking-agentic": "kr/claude-opus-4.8-thinking-agentic",
    "deepseek-3.2": "kr/deepseek-3.2",
    "qwen3-coder-next": "kr/qwen3-coder-next",
    "glm-5": "kr/glm-5",
    "minimax-m2.5": "kr/minimax-m2.5",
    "minimax-m2.1": "kr/minimax-m2.1"
  };
  return map[normalized] || canonicalizeApiModelId(normalized);
}

function normalizeModelName(value) {
  return String(value || "")
    .trim()
    .replace(/\x1b\[[0-9;]*m/g, "")
    .replace(/\[1m\]$/i, "")
    .toLowerCase();
}

function canonicalizeApiModelId(value) {
  if (!/^(kr|ag)\//.test(value)) return value;
  return value
    .replace(/^kr\/claude-opus-4-(\d)(?=$|-)/, "kr/claude-opus-4.$1")
    .replace(/^kr\/claude-sonnet-4-(\d)(?=$|-)/, "kr/claude-sonnet-4.$1")
    .replace(/^kr\/claude-haiku-4-(\d)(?=$|-)/, "kr/claude-haiku-4.$1");
}

function parseOpenAiMessage(text) {
  const trimmed = String(text || "").trim();
  if (trimmed.startsWith("data:")) return parseOpenAiSseMessage(trimmed);

  try {
    const parsed = JSON.parse(trimmed);
    const choice = parsed.choices?.[0] || {};
    const message = choice.message || {};
    const content = Array.isArray(message.content)
      ? message.content.map(contentPartToText).filter(Boolean).join("\n")
      : String(message.content || "");
    return {
      text: content,
      toolCalls: normalizeOpenAiToolCalls(message.tool_calls || []),
      finishReason: choice.finish_reason || null,
      usage: parsed.usage || null
    };
  } catch {
    return { text: trimmed, toolCalls: [], finishReason: "stop", usage: null };
  }
}

function parseOpenAiSseMessage(text) {
  let answer = "";
  let finishReason = null;
  let usage = null;
  const toolCallsByIndex = new Map();

  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("data:")) continue;
    const data = trimmed.slice(5).trim();
    if (!data || data === "[DONE]") continue;
    try {
      const parsed = JSON.parse(data);
      const choice = parsed.choices?.[0] || {};
      const delta = choice.delta || {};
      const message = choice.message || {};
      answer += delta.content || message.content || "";
      finishReason = choice.finish_reason || finishReason;
      usage = parsed.usage || usage;

      for (const toolCall of delta.tool_calls || message.tool_calls || []) {
        mergeOpenAiToolCall(toolCallsByIndex, toolCall);
      }
    } catch {
      // Ignora linhas auxiliares que nao forem JSON.
    }
  }

  return {
    text: answer.trim(),
    toolCalls: normalizeMergedToolCalls(toolCallsByIndex),
    finishReason,
    usage
  };
}

function mergeOpenAiToolCall(toolCallsByIndex, toolCall) {
  const index = Number.isInteger(toolCall.index) ? toolCall.index : toolCallsByIndex.size;
  const current = toolCallsByIndex.get(index) || {
    id: "",
    type: "function",
    name: "",
    arguments: ""
  };

  if (toolCall.id) current.id = String(toolCall.id);
  if (toolCall.type) current.type = String(toolCall.type);
  if (toolCall.function?.name) current.name = String(toolCall.function.name);
  if (typeof toolCall.function?.arguments === "string") current.arguments += toolCall.function.arguments;
  if (toolCall.function?.arguments && typeof toolCall.function.arguments !== "string") {
    current.arguments += JSON.stringify(toolCall.function.arguments);
  }

  toolCallsByIndex.set(index, current);
}

function normalizeOpenAiToolCalls(toolCalls) {
  const merged = new Map();
  for (const toolCall of toolCalls || []) mergeOpenAiToolCall(merged, toolCall);
  return normalizeMergedToolCalls(merged);
}

function normalizeMergedToolCalls(toolCallsByIndex) {
  return [...toolCallsByIndex.entries()]
    .sort(([a], [b]) => a - b)
    .map(([, toolCall]) => ({
      id: toolCall.id || `toolu_${crypto.randomBytes(8).toString("hex")}`,
      name: toolCall.name,
      input: parseJsonObject(toolCall.arguments)
    }))
    .filter((toolCall) => toolCall.name);
}

function parseJsonObject(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  const text = String(value || "").trim();
  if (!text) return {};
  try {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed;
    return { value: parsed };
  } catch {
    return { value: text };
  }
}

function stopReasonFromOpenAiResult(result) {
  if ((result.toolCalls || []).length) return "tool_use";
  if (result.finishReason === "length") return "max_tokens";
  return "end_turn";
}

function usageFromOpenAiResult(result, body) {
  return {
    input_tokens: result.usage?.prompt_tokens || estimateTokens(JSON.stringify(body.messages || [])),
    output_tokens: result.usage?.completion_tokens || estimateTokens(`${result.text || ""}${JSON.stringify(result.toolCalls || [])}`)
  };
}

async function fetchWithTimeout(url, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function isAuthorized(req) {
  const auth = req.headers.authorization || "";
  const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : req.headers["x-api-key"];
  if (!token) return false;
  const a = Buffer.from(hash(token));
  const b = Buffer.from(hash(adapterApiKey));
  return crypto.timingSafeEqual(a, b);
}

function unauthorized(res) {
  return sendJson(res, 401, {
    error: {
      type: "authentication_error",
      message: "Chave do adaptador invalida."
    }
  });
}

function getAdapterApiKey() {
  if (process.env.ADAPTER_API_KEY) return process.env.ADAPTER_API_KEY;
  if (fs.existsSync(keyPath)) return fs.readFileSync(keyPath, "utf8").trim();
  const key = `abca_${crypto.randomBytes(32).toString("base64url")}`;
  fs.writeFileSync(keyPath, `${key}\n`, "utf8");
  return key;
}

function loadDotEnv(filePath) {
  if (!fs.existsSync(filePath)) return;
  const lines = fs.readFileSync(filePath, "utf8").split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const index = trimmed.indexOf("=");
    if (index === -1) continue;
    const key = trimmed.slice(0, index).trim();
    let value = trimmed.slice(index + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    if (!process.env[key]) process.env[key] = value;
  }
}

function readRawBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(new Error("Corpo da requisicao muito grande."));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function writeSse(res, event, payload) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function sendJson(res, status, payload) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.end(JSON.stringify(payload, null, 2));
}

function appendLog(entry) {
  try {
    fs.appendFileSync(logPath, `${JSON.stringify(entry)}\n`, "utf8");
  } catch {
    // Log local nao deve derrubar o adaptador.
  }
}

function estimateTokens(text) {
  return Math.max(1, Math.ceil(String(text || "").length / 4));
}

function redact(text) {
  return String(text || "")
    .replace(/sk-[A-Za-z0-9_-]+/g, "[redacted]")
    .replace(/abca_[A-Za-z0-9_-]+/g, "[redacted]");
}

function trimSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function hash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}
