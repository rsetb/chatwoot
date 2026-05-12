const INSTANCE = 'rafael';
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

fetch('http://127.0.0.1:8080/chatwoot/set/' + INSTANCE, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', apikey: APIKEY },
  body: JSON.stringify(payload),
})
  .then(async (r) => {
    console.log('SET STATUS:', r.status);
    console.log(await r.text());
  })
  .catch(console.error);