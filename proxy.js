export default {
  async fetch(request, env, ctx) {
    // 1. 解析原始 URL
    const url = new URL(request.url);

    // 2. 将目标域名修改为 Google Gemini 官方域名
    url.hostname = 'generativelanguage.googleapis.com';
    // 确保协议是 HTTPS
    url.protocol = 'https:';
    // 端口重置（防止如果你的 worker 用了非标准端口带过去）
    url.port = '';

    // 3. 重新构建请求头 (关键修改步骤)
    // 我们必须创建一个新的 Headers 对象，并剔除原始的 Host 头
    const newHeaders = new Headers(request.headers);
    
    // 移除 Host 头，让 fetch 自动根据上面的 url.hostname 生成正确的 Host
    newHeaders.delete('Host');
    // 移除 Referer 和 Origin，避免触发 Google 的来源检查（可选，但更稳妥）
    newHeaders.delete('Referer');
    newHeaders.delete('Origin');

    // 4. 构建新的 Request 对象
    const newRequest = new Request(url, {
      method: request.method,
      headers: newHeaders,
      body: request.body,
      redirect: 'follow'
    });

    // 5. 发起请求并处理错误
    try {
      const response = await fetch(newRequest);
      
      // 创建新的响应对象以处理跨域头（虽然原生 App 不强制，但建议加上）
      const newResponse = new Response(response.body, response);
      newResponse.headers.set('Access-Control-Allow-Origin', '*');
      newResponse.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      newResponse.headers.set('Access-Control-Allow-Headers', '*');
      
      return newResponse;
    } catch (e) {
      // 返回详细的错误信息以便调试
      return new Response(JSON.stringify({ 
          error: e.message,
          location: 'Cloudflare Worker Catch' 
      }), { 
          status: 500,
          headers: { 'Content-Type': 'application/json' }
      });
    }
  },
};
