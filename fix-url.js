const APIKEY = process.env.AUTHENTICATION_API_KEY;

const payload = {
  enabled: true,
  accountId: '1',
  token: '58awgivzRL8Pg4SjCkorTL8D',
  url: 'https://evolutionapi-chatwoot.znvdsb.easypanel.host',
  nameInbox: 'rafa',
  autoCreate: true,
  importContacts: true,
  importMessages: true,
  daysLimitImportMessages: 365,
  reopenConversation: true,
  conversationPending: false,
  signMsg: true,
  signDelimiter: '\n'
};

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
      
      const r = await fetch('http://127.0.0.1:8080/chatwoot/set/' + instanceName, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: APIKEY },
        body: JSON.stringify(payload),
      });
      
      console.log('SET STATUS:', r.status);
      console.log(await r.text());
      console.log('========================================\n');
    }
  })
  .catch(console.error);
