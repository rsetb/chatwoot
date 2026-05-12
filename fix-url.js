const APIKEY = process.env.AUTHENTICATION_API_KEY;

function sanitizeUrl(raw) {
  if (!raw) return raw;
  const cleaned = String(raw).replace(/`/g, '').trim();
  return cleaned.replace(/\/+$/, '');
}

function sanitizeText(raw) {
  if (raw === undefined || raw === null) return raw;
  return String(raw).replace(/`/g, '').trim();
}

async function fetchJson(url, options = {}) {
  const r = await fetch(url, options);
  const text = await r.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: r.status, text, json };
}

fetch('http://127.0.0.1:8080/instance/fetchInstances', {
  headers: { apikey: APIKEY }
})
  .then(r => r.json())
  .then(async data => {
    if (!data || !Array.isArray(data) || data.length === 0) {
      console.log('No instances found!');
      return;
    }
    
    for (const inst of data) {
      const instanceName = inst?.instance?.instanceName || inst?.instanceName || inst?.name;
      if (!instanceName) {
        console.log('Could not parse instance name from:', inst);
        continue;
      }
      console.log('\n========================================');
      console.log('Updating Chatwoot config for instance:', instanceName);

      const findResult = await fetchJson('http://127.0.0.1:8080/chatwoot/find/' + instanceName, {
        headers: { apikey: APIKEY }
      });

      if (findResult.status !== 200 || !findResult.json) {
        console.log('FIND STATUS:', findResult.status);
        console.log(findResult.text);
        console.log('Skipping set because current Chatwoot config could not be read.');
        console.log('========================================\n');
        continue;
      }

      const current = findResult.json;
      const token = sanitizeText(current.token || process.env.CHATWOOT_TOKEN);
      const accountId = sanitizeText(current.accountId || current.account_id || process.env.CHATWOOT_ACCOUNT_ID || '1');
      const url = sanitizeUrl(current.url || current.chatwootUrl || process.env.CHATWOOT_URL);

      if (!token || !url) {
        console.log('Missing token or url. token?', Boolean(token), 'url?', Boolean(url));
        console.log('========================================\n');
        continue;
      }

      const payload = {
        enabled: true,
        accountId,
        token,
        url,
        nameInbox: sanitizeText(current.nameInbox || current.name_inbox || instanceName),
        autoCreate: true,
        mergeBrazilContacts: current.mergeBrazilContacts ?? true,
        importContacts: true,
        importMessages: true,
        daysLimitImportMessages: Number(process.env.CHATWOOT_DAYS_LIMIT_IMPORT_MESSAGES || current.daysLimitImportMessages || 365),
        reopenConversation: current.reopenConversation ?? true,
        conversationPending: current.conversationPending ?? false,
        signMsg: current.signMsg ?? true,
        signDelimiter: '\n'
      };

      const setResult = await fetchJson('http://127.0.0.1:8080/chatwoot/set/' + instanceName, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: APIKEY },
        body: JSON.stringify(payload),
      });

      console.log('SET STATUS:', setResult.status);
      console.log(setResult.text);
      console.log('========================================\n');
    }
  })
  .catch(console.error);
