// Generate language-neutral v1 behavior fixtures using the JavaScript contract reference.
// Synthetic source only. No Codex executable, login file, or network is used.
import {writeFileSync} from 'node:fs';
import {createEngine} from '../reference/core/engine.js';
import {initialState} from '../reference/core/state.js';
const baseSnapshot=()=>({identity:{accountId:'account-a',scope:'workspace-a',email:'demo@example.test'},availableCount:2,remainingPercent:90,credits:[{id:'a',expiresAt:120*60000},{id:'b',expiresAt:125*60000}]});
const cases=[
 {name:'mock-window-and-manual',mode:'mock',steps:[{op:'configure',patch:{enabled:true}},{op:'tick',at:109.99},{op:'tick',at:110,manual:true},{op:'tick'},{op:'tick'}]},
 {name:'live-binding-roundtrip',mode:'live',steps:[{op:'tick',manual:true},{op:'configure',patch:{enabled:true},autoConsent:true},{op:'tick'},{op:'source',scope:'other'},{op:'tick'},{op:'source',scope:'workspace-a'},{op:'restart'},{op:'tick'}]},
 {name:'live-lost-response-negative',mode:'live',steps:[{op:'tick',manual:true},{op:'configure',patch:{enabled:true},autoConsent:true},{op:'source',loseResponse:true},{op:'tick',at:110},{op:'restart'},{op:'source',loseResponse:false,result:'no-credit'},{op:'tick',at:111},{op:'tick'}]},
 {name:'live-no-credit-inventory-gate',mode:'live',steps:[{op:'tick',manual:true},{op:'configure',patch:{enabled:true},autoConsent:true},{op:'source',result:'no-credit'},{op:'tick',at:116},{op:'tick'},{op:'source',dropFirst:true,result:'reset'},{op:'tick'}]},
 {name:'rejected-usage-revision',mode:'mock',steps:[{op:'configure',patch:{enabled:true}},{op:'source',result:'nothing-to-reset'},{op:'tick',at:110},{op:'tick'},{op:'source',remainingPercent:89,result:'reset'},{op:'tick'}]},
 {name:'confirmed-receipt-restart',mode:'mock',steps:[{op:'configure',patch:{enabled:true}},{op:'source',failAfterConsume:true},{op:'tick',at:110},{op:'source',failRead:false,failAfterConsume:false},{op:'restart'},{op:'tick'}]}
];
for(const scenario of cases){
 let at=100*60000,counter=0,durable=initialState(),snapshot=baseSnapshot(),result='reset',loseResponse=false,failRead=false,failAfterConsume=false;
 const requests=[];
 const source={mode:scenario.mode,async read(){if(failRead)throw Object.assign(new Error('read-failed'),{code:'read-failed'});return structuredClone(snapshot);},async consume({id,key,startsAt,expiresAt,recovering,maySend}){if(!maySend())throw Object.assign(new Error('cancelled'),{code:'cancelled',notSent:true});requests.push({id,key,startsAt,expiresAt,recovering});if(failAfterConsume)failRead=true;if(loseResponse)throw new Error('lost');return result;}};
 const create=()=>createEngine({source,now:()=>at,key:()=>`key-${++counter}`,store:{read:()=>structuredClone(durable),async write(s){durable=structuredClone(s);}}});
 let engine=create();scenario.initialSnapshot=baseSnapshot();
 for(const step of scenario.steps){
  if(step.at!=null)at=step.at*60000;
  if(step.op==='source'){
   if(step.scope)snapshot.identity.scope=step.scope;
   if(step.dropFirst){snapshot.credits.shift();snapshot.availableCount=snapshot.credits.length;}
   for(const k of ['remainingPercent'])if(k in step)snapshot[k]=step[k];
   if('result'in step)result=step.result;if('loseResponse'in step)loseResponse=step.loseResponse;if('failRead'in step)failRead=step.failRead;if('failAfterConsume'in step)failAfterConsume=step.failAfterConsume;
  }else if(step.op==='restart')engine=create();
  else if(step.op==='configure'){const patch={...step.patch};if(step.autoConsent)patch.consent=engine.view().consent;await engine.configure(patch);}
  else if(step.op==='tick')await engine.tick({manual:step.manual??false});
  step.expected={view:engine.view(),state:structuredClone(durable),requests:structuredClone(requests)};
 }
}
writeFileSync(new URL('./native-engine-vectors.json',import.meta.url),JSON.stringify(cases,null,2)+'\n');
