/**
 * Cloudflare Worker for Gemini AI (内置 API Key 版)
 */

// 1. 在这里填入你的 API Key (或者在 Cloudflare 控制台设置环境变量 GEMINI_API_KEY)
const BUILTIN_API_KEY = "在此处填入你的_API_KEY"; 

// 推荐模型：gemini-1.5-flash (速度快、免费额度高) 或 gemini-1.5-pro
const DEFAULT_MODEL = "gemini-3-flash-preview";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 1. 根路径返回 HTML
    if (url.pathname === "/" && request.method === "GET") {
      // 检查是否已经配置了 Key (无论是环境变量还是内置变量)
      const hasServerKey = !!(env.GEMINI_API_KEY || BUILTIN_API_KEY);
      return new Response(renderHTML(url.searchParams.get("key"), hasServerKey), {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    // 2. API 接口处理
    if (url.pathname === "/api/chat" && request.method === "POST") {
      return handleChatRequest(request, env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

/**
 * 处理后端 API 请求
 */
async function handleChatRequest(request, env) {
  try {
    const body = await request.json();
    const messages = body.messages || [];
    
    if (messages.length === 0) {
        return new Response(JSON.stringify({ error: { message: "消息内容为空" } }), { status: 400 });
    }

    // 优先级：环境变量 > 代码内置 > 前端传入
    const apiKey = env.GEMINI_API_KEY || BUILTIN_API_KEY || body.apiKey;

    if (!apiKey || apiKey === "在此处填入你的_API_KEY") {
      return new Response(JSON.stringify({ error: { message: "管理员未配置 API Key，请联系管理员或在 URL 后添加 ?key=你的Key" } }), {
        status: 401,
        headers: { "Content-Type": "application/json" }
      });
    }

    const apiUrl = `https://generativelanguage.googleapis.com/v1beta/models/${DEFAULT_MODEL}:generateContent?key=${apiKey}`;

    const googleResponse = await fetch(apiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: messages,
        generationConfig: {
            temperature: 0.7,
            maxOutputTokens: 2048,
        }
      }),
    });

    const data = await googleResponse.json();
    
    if (!googleResponse.ok) {
        return new Response(JSON.stringify(data), { 
            status: googleResponse.status,
            headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } 
        });
    }
    
    return new Response(JSON.stringify(data), {
      headers: { 
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*" 
      },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: { message: err.message } }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
}

/**
 * 前端 HTML
 */
function renderHTML(urlKey, hasServerKey) {
  const keyStatus = hasServerKey ? "已配置内置 Key" : "未配置 Key";

  return `
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gemini AI Pro</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; display: flex; flex-direction: column; height: 100vh; background: #f0f2f5; }
        #chat-box { flex: 1; overflow-y: auto; padding: 20px; scroll-behavior: smooth; }
        .msg { margin-bottom: 15px; padding: 12px 16px; border-radius: 12px; max-width: 85%; word-break: break-word; line-height: 1.6; box-shadow: 0 1px 2px rgba(0,0,0,0.1); }
        .user { background: #007bff; color: white; align-self: flex-end; margin-left: auto; border-bottom-right-radius: 2px; }
        .ai { background: white; color: #333; align-self: flex-start; margin-right: auto; border-bottom-left-radius: 2px; }
        .error { background: #ffeef0; color: #d73a49; border: 1px solid #ffcfd3; align-self: center; width: 90%; text-align: center; }
        #input-container { display: flex; padding: 20px; background: white; border-top: 1px solid #ddd; }
        input { flex: 1; padding: 12px; border: 1px solid #ddd; border-radius: 8px; outline: none; font-size: 16px; }
        input:focus { border-color: #007bff; }
        button { padding: 10px 24px; margin-left: 10px; background: #28a745; color: white; border: none; border-radius: 8px; cursor: pointer; font-size: 16px; }
        button:hover { background: #218838; }
        button:disabled { background: #ccc; }
        pre { background: #f4f4f4; padding: 10px; border-radius: 5px; overflow-x: auto; white-space: pre-wrap; font-size: 14px; }
        .status-badge { position: fixed; top: 10px; right: 10px; font-size: 12px; padding: 4px 8px; border-radius: 4px; background: #e0e0e0; color: #666; }
    </style>
</head>
<body>

<div class="status-badge">${keyStatus}</div>

<div id="chat-box" style="display: flex; flex-direction: column;">
    <div class="msg ai">你好！我是 Gemini AI。我已经准备好进行连续对话了。${hasServerKey ? '' : '<br><span style="color:red">注意：检测到服务器未配置 API Key，对话可能无法进行。</span>'}</div>
</div>

<div id="input-container">
    <input type="text" id="user-input" placeholder="输入对话内容..." autocomplete="off">
    <button id="send-btn">发送</button>
    <button id="reset-btn" style="background: #6c757d; margin-left: 5px;">重置</button>
</div>

<script>
    const urlKey = "${urlKey || ''}";
    const chatBox = document.getElementById('chat-box');
    const userInput = document.getElementById('user-input');
    const sendBtn = document.getElementById('send-btn');
    const resetBtn = document.getElementById('reset-btn');

    let conversationHistory = [];

    function addMessage(role, text) {
        const div = document.createElement('div');
        div.className = \`msg \${role}\`;
        
        if (role === 'ai') {
            let formatted = text
                .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") 
                .replace(/\\n/g, '<br>')
                .replace(/\\*\\*(.*?)\\*\\*/g, '<b>$1</b>')
                .replace(/\\\`\\\`\\\`([\\s\\S]*?)\\\`\\\`\\\`/g, '<pre><code>$1</code></pre>')
                .replace(/\\\`(.*?)\\\`/g, '<code>$1</code>');
            div.innerHTML = formatted; 
        } else {
            div.textContent = text;
        }
        
        chatBox.appendChild(div);
        chatBox.scrollTop = chatBox.scrollHeight;
    }

    async function callGemini() {
        const prompt = userInput.value.trim();
        if (!prompt) return;

        addMessage('user', prompt);
        userInput.value = '';
        sendBtn.disabled = true;
        sendBtn.innerText = '...';

        conversationHistory.push({
            role: "user",
            parts: [{ text: prompt }]
        });

        try {
            const response = await fetch('/api/chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    messages: conversationHistory,
                    apiKey: urlKey // 即使是空的也会发送，后端会处理
                })
            });

            const data = await response.json();

            if (!response.ok) {
                conversationHistory.pop();
                throw new Error(data.error?.message || '请求失败');
            }

            if (data.candidates && data.candidates[0].content) {
                const aiText = data.candidates[0].content.parts[0].text;
                addMessage('ai', aiText);
                conversationHistory.push({
                    role: "model",
                    parts: [{ text: aiText }]
                });
            } else {
                conversationHistory.pop();
                addMessage('error', 'API 返回内容异常，请重试。');
            }
        } catch (err) {
            addMessage('error', '错误: ' + err.message);
        } finally {
            sendBtn.disabled = false;
            sendBtn.innerText = '发送';
            userInput.focus();
        }
    }

    resetBtn.addEventListener('click', () => {
        conversationHistory = [];
        chatBox.innerHTML = '<div class="msg ai">对话已重置。</div>';
    });

    sendBtn.addEventListener('click', callGemini);
    userInput.addEventListener('keypress', (e) => { if (e.key === 'Enter') callGemini(); });
    userInput.focus();
</script>

</body>
</html>
  `;
}
