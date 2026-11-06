import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
const sha=s=>createHash('sha256').update(s).digest('hex');
const digest=v=>sha(JSON.stringify(v));
const entries=['demo@example.test','角色/"\\@example.test','e\u0301@example.test','é@example.test','Ω🙂@example.test'].map((email,i)=>{
 const identity={accountId:`workspace/${i}`,scope:'codex:'+sha(email),email};
 const authorization=digest(['reset-rune-live-v1',identity.accountId,identity.scope]);
 const lead=[5,10,30,60,10][i];
 const credits=[{id:'a',expiresAt:1000},{id:'A',expiresAt:2000},{id:'é',expiresAt:3000},{id:'e\u0301',expiresAt:4000},{id:'/',expiresAt:5000}];
 return {identity,lead,authorization,consent:digest([authorization,lead]),credits,inventoryRevision:digest([credits.length,credits.map(c=>[c.id,c.expiresAt]).sort(([a],[b])=>a.localeCompare(b))])};
});
writeFileSync(new URL('./native-hash-vectors.json',import.meta.url),JSON.stringify(entries,null,2)+'\n');
