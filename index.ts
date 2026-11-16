// Trendos Camp Management — server function "trendos-api"  (app v6.0)
// Keeps the Claude API key and the WhatsApp token on the server, never in the app.
// Only signed-in, active Trendos users can call it.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   ANTHROPIC_API_KEY   Claude API key (for Iqama scan, Ask AI, email drafts, summaries)
//   AI_DAILY_LIMIT      optional, AI requests per person per day (default 200, 0 = no limit)
//   WA_TOKEN            optional, WhatsApp Business permanent access token
//   WA_PHONE_ID         optional, WhatsApp Business phone number ID
//   WA_API_VERSION      optional, Graph API version (default v26.0)

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const env = (k: string): string => (Deno.env.get(k) || '').trim();

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);
  try {
    const auth = req.headers.get('Authorization') || '';
    const apikey = req.headers.get('apikey') || env('SUPABASE_ANON_KEY');
    if (!auth.startsWith('Bearer ')) return json({ error: 'Sign in first' }, 401);
    const base = env('SUPABASE_URL');
    const rest = (path: string, init: RequestInit = {}): Promise<Response> =>
      fetch(base + path, { ...init, headers: { apikey, Authorization: auth, 'Content-Type': 'application/json', ...(init.headers || {}) } });
    const rpc = async (fn: string, args: Record<string, unknown> = {}): Promise<any> => {
      const r = await rest('/rest/v1/rpc/' + fn, { method: 'POST', body: JSON.stringify(args) });
      if (!r.ok) throw new Error(`${fn} failed (${r.status}) — has supabase-upgrade-v6.sql been run?`);
      return r.json();
    };

    // who is calling?
    const ur = await rest('/auth/v1/user');
    if (!ur.ok) return json({ error: 'Your session has expired. Sign in again.' }, 401);
    const user: any = await ur.json();
    const pr = await rest(`/rest/v1/trendos_users?id=eq.${encodeURIComponent(user.id)}&select=role,active`);
    const prof: any = pr.ok ? (await pr.json())[0] : null;
    if (!prof || !prof.active) return json({ error: 'Your account is not active.' }, 403);

    const body: any = await req.json().catch(() => ({}));
    const aiLimit = Number(env('AI_DAILY_LIMIT') || 200);

    switch (body.action) {
      case 'status': {
        let aiToday = 0;
        try { aiToday = await rpc('trendos_ai_today'); } catch (_) { /* table not created yet */ }
        return json({ ai: !!env('ANTHROPIC_API_KEY'), whatsapp: !!(env('WA_TOKEN') && env('WA_PHONE_ID')), aiToday, aiLimit });
      }

      case 'ai': {
        const key = env('ANTHROPIC_API_KEY');
        if (!key) return json({ error: 'AI is not set up yet: add the ANTHROPIC_API_KEY secret in Supabase → Edge Functions → Secrets.' }, 400);
        const p: any = body.payload || {};
        if (typeof p.model !== 'string' || !/^claude-[a-z0-9.\-]+$/.test(p.model)) return json({ error: 'Unknown AI model name.' }, 400);
        if (!Array.isArray(p.messages) || !p.messages.length) return json({ error: 'Nothing to send.' }, 400);
        const request: Record<string, unknown> = { model: p.model, max_tokens: Math.min(Math.max(Number(p.max_tokens) || 1024, 1), 4000), messages: p.messages };
        if (typeof p.system === 'string') request.system = p.system.slice(0, 20000);
        if (Array.isArray(p.tools)) request.tools = p.tools.slice(0, 20);
        if (p.tool_choice && typeof p.tool_choice === 'object') request.tool_choice = p.tool_choice;
        if (JSON.stringify(request).length > 3_000_000) return json({ error: 'The request is too large (photo too big?).' }, 413);
        const n = await rpc('trendos_ai_tick');
        if (aiLimit > 0 && n > aiLimit) return json({ error: `Daily AI limit reached (${aiLimit} requests per person). It resets tomorrow.` }, 429);
        const r = await fetch('https://api.anthropic.com/v1/messages', {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
          body: JSON.stringify(request),
        });
        const j: any = await r.json().catch(() => ({}));
        if (!r.ok) return json({ error: (j && j.error && j.error.message) || `AI request failed (${r.status})` }, r.status === 429 ? 429 : 502);
        return json(j);
      }

      case 'whatsapp': {
        const token = env('WA_TOKEN'), phoneId = env('WA_PHONE_ID');
        if (!token || !phoneId) return json({ error: 'WhatsApp is not set up yet: add the WA_TOKEN and WA_PHONE_ID secrets.' }, 400);
        if ((await rpc('trendos_can_edit', { p_collection: 'residents' })) !== true) return json({ error: 'Your role cannot send messages.' }, 403);
        const to = String(body.to || '').replace(/\D/g, '');
        if (!/^\d{8,15}$/.test(to)) return json({ error: 'Invalid phone number.' }, 400);
        const template = String(body.template || '');
        if (!/^[a-z0-9_]{1,512}$/.test(template)) return json({ error: 'Invalid template name.' }, 400);
        const lang = /^[a-z]{2}(_[A-Z]{2})?$/.test(String(body.lang || '')) ? String(body.lang) : 'en';
        const params = (Array.isArray(body.params) ? body.params : []).slice(0, 10)
          .map((x: unknown) => ({ type: 'text', text: (String(x ?? '').replace(/[\n\t]+/g, ' ').slice(0, 1000)) || '-' }));
        const r = await fetch(`https://graph.facebook.com/${env('WA_API_VERSION') || 'v26.0'}/${phoneId}/messages`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            messaging_product: 'whatsapp', recipient_type: 'individual', to, type: 'template',
            template: { name: template, language: { code: lang }, components: params.length ? [{ type: 'body', parameters: params }] : [] },
          }),
        });
        const j: any = await r.json().catch(() => ({}));
        if (!r.ok) return json({ error: (j && j.error && j.error.message) || `WhatsApp failed (${r.status})` }, 502);
        return json({ id: (j.messages && j.messages[0] && j.messages[0].id) || '' });
      }

      default:
        return json({ error: 'Unknown action' }, 400);
    }
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
