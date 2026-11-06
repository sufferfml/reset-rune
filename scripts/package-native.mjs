#!/usr/bin/env node
// INPUT: locked Swift source and original assets. OUTPUT: local native DMGs/npm packages; no publishing.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, writeFile, mkdir, cp, rm, stat, readdir, chmod } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const run=promisify(execFile), root=fileURLToPath(new URL('../',import.meta.url));
const args=process.argv.slice(2), version='0.1.0', signed=args.includes('--signed'), notarize=args.includes('--notarize');
const archArg=args.indexOf('--arch'), arches=archArg<0||args[archArg+1]==='all' ? ['arm64','x64']:[args[archArg+1]];
if (arches.some(a=>!['arm64','x64'].includes(a))) throw Error('Use --arch arm64, x64 or all');
if(notarize&&!signed)throw Error('--notarize requires --signed');
const exec=async(file,argv,opts={})=>run(file,argv,{cwd:root,maxBuffer:32*1024*1024,...opts});
let identity='-';
if(signed){
 const {stdout}=await exec('/usr/bin/security',['find-identity','-v','-p','codesigning']);
 const matches=[...stdout.matchAll(/([A-F0-9]{40})\s+"(Developer ID Application:[^"]+)"/g)].filter(m=>!process.env.CSC_NAME||m[1]===process.env.CSC_NAME||m[2].includes(process.env.CSC_NAME));
 if(matches.length!==1)throw Error('Select one Developer ID with CSC_NAME'); identity=matches[0][1];
}
const sign=async(file)=>exec('/usr/bin/codesign',['--force','--sign',identity,...(signed?['--options','runtime','--timestamp']:['--timestamp=none']),file]);
const plist=async(file,obj)=>{await writeFile(file,JSON.stringify(obj));await exec('/usr/bin/plutil',['-convert','xml1',file]);};
const artifacts=[];
const out=path.join(root,'dist/native');await mkdir(out,{recursive:true});
async function inputs(dir){const files=[];for(const item of await readdir(path.join(root,dir),{withFileTypes:true})){if(item.name.startsWith('.'))continue;const rel=path.join(dir,item.name);if(item.isDirectory())files.push(...await inputs(rel));else files.push(rel);}return files;}
const inputPaths=[...(await inputs('native/Sources')),'native/Package.swift','native/Package.resolved','distribution/npm/cli.cjs','scripts/package-native.mjs',...(await inputs('assets/panel')),...(await inputs('assets/icons'))];
const digestInputs=async()=>Object.fromEntries(await Promise.all(inputPaths.map(async f=>[f,createHash('sha256').update(await readFile(path.join(root,f))).digest('hex')])));
const sourceDigests=await digestInputs();
for(const arch of arches){
 console.log(`Building native ${arch}`);
 const triple=arch==='arm64'?'arm64-apple-macosx13.0':'x86_64-apple-macosx13.0';
 const buildArgs=['build','--package-path','native','-c','release','--triple',triple];
 await exec('/usr/bin/xcrun',['swift',...buildArgs]);
 const {stdout:binpath}=await exec('/usr/bin/xcrun',['swift',...buildArgs,'--show-bin-path']);
 const bin=binpath.trim(), dir=path.join(out,arch), app=path.join(dir,'Bottled Reset Rune.app');
 await rm(dir,{recursive:true,force:true}); await mkdir(path.join(app,'Contents/MacOS'),{recursive:true});
 const resources=path.join(app,'Contents/Resources');await mkdir(resources,{recursive:true});
 const helper=path.join(app,'Contents/Helpers/Bottled Reset Rune Service.app');await mkdir(path.join(helper,'Contents/MacOS'),{recursive:true});
 await cp(path.join(bin,'BottledResetRuneMenu'),path.join(app,'Contents/MacOS/Bottled Reset Rune'));
 await cp(path.join(bin,'reset-rune'),path.join(helper,'Contents/MacOS/reset-rune'));
 for(const file of [path.join(app,'Contents/MacOS/Bottled Reset Rune'),path.join(helper,'Contents/MacOS/reset-rune')]){await chmod(file,0o755);await exec('/usr/bin/strip',['-S',file]);}
 const common={CFBundlePackageType:'APPL',CFBundleShortVersionString:version,CFBundleVersion:'100',LSMinimumSystemVersion:'13.0',NSHighResolutionCapable:true};
 await plist(path.join(helper,'Contents/Info.plist'),{...common,CFBundleIdentifier:'local.reset-rune.runtime',CFBundleExecutable:'reset-rune',CFBundleName:'Bottled Reset Rune Service',LSBackgroundOnly:true});
 await plist(path.join(app,'Contents/Info.plist'),{...common,CFBundleIdentifier:'local.reset-rune.desktop',CFBundleExecutable:'Bottled Reset Rune',CFBundleName:'Bottled Reset Rune',CFBundleDisplayName:'Bottled Reset Rune',CFBundleIconFile:'icon',LSUIElement:true,BottledResetRuneNative:true,NSAppTransportSecurity:{NSAllowsLocalNetworking:true}});
 for(const name of ['bottle.png','bottle-empty.png'])await cp(path.join(root,'assets/panel',name),path.join(resources,name));
 for(const name of ['icon.icns','trayTemplate.png','trayTemplate@2x.png','trayEmptyTemplate.png','trayEmptyTemplate@2x.png','trayUnknownTemplate.png','trayUnknownTemplate@2x.png'])await cp(path.join(root,'assets/icons',name),path.join(resources,name));
 await cp(path.join(root,'LICENSE'),path.join(resources,'LICENSE'));await writeFile(path.join(resources,'THIRD_PARTY.txt'),'SwiftNIO and its locked dependencies are distributed under their respective licenses.\n');
 for(const dependency of ['swift-nio','swift-atomics','swift-collections','swift-system']){
  const source=path.join(root,'native/.build/checkouts',dependency);const names=await readdir(source);
  for(const name of names.filter(n=>/^LICENSE|^NOTICE/.test(n)))await cp(path.join(source,name),path.join(resources,`${dependency}-${name}`));
 }
 await sign(helper);await sign(app);
 if(notarize){
  for(const bundle of [helper,app]){
   if(bundle===app)await sign(app);
   // A prior accepted submission for identical signed code can already supply a ticket.
   let ticket=false;
   try{await exec('/usr/bin/xcrun',['stapler','staple',bundle]);await exec('/usr/bin/xcrun',['stapler','validate',bundle]);ticket=true;}catch{}
   if(ticket)continue;
   const zip=path.join(out,`notary-${arch}-${path.basename(bundle)}.zip`);
   await exec('/usr/bin/ditto',['-c','-k','--keepParent',bundle,zip]);
   await exec('/usr/bin/xcrun',['notarytool','submit',zip,'--keychain-profile',process.env.RESET_RUNE_NOTARY_PROFILE||'reset-rune-notary','--wait'],{timeout:600_000});
   await exec('/usr/bin/xcrun',['stapler','staple',bundle]);await rm(zip);
  }
 }
 await exec('/usr/bin/codesign',['--verify','--deep','--strict',app]);
 const stage=path.join(out,`dmg-stage-${arch}`);await rm(stage,{recursive:true,force:true});await mkdir(stage,{recursive:true});await cp(app,path.join(stage,'Bottled Reset Rune.app'),{recursive:true});
 await exec('/bin/ln',['-s','/Applications',path.join(stage,'Applications')]);
 const dmg=path.join(out,`Bottled-Reset-Rune-${version}-${arch}.dmg`);await rm(dmg,{force:true});
 await exec('/usr/bin/hdiutil',['create','-quiet','-volname','Bottled Reset Rune','-srcfolder',stage,'-format','UDZO',dmg]);await rm(stage,{recursive:true,force:true});
 if(signed)await sign(dmg);
 if(notarize){await exec('/usr/bin/xcrun',['notarytool','submit',dmg,'--keychain-profile',process.env.RESET_RUNE_NOTARY_PROFILE||'reset-rune-notary','--wait'],{timeout:600_000});await exec('/usr/bin/xcrun',['stapler','staple',dmg]);}
 const platform=path.join(out,`npm-${arch}`);await rm(platform,{recursive:true,force:true});await mkdir(platform,{recursive:true});await cp(app,path.join(platform,'Bottled Reset Rune.app'),{recursive:true});
 await writeFile(path.join(platform,'package.json'),JSON.stringify({name:`reset-rune-darwin-${arch}`,version,description:'Native Bottled Reset Rune runtime',license:'MIT',os:['darwin'],cpu:[arch],files:['Bottled Reset Rune.app']},null,2));
 const {stdout:packed}=await exec('npm',['pack','--json','--ignore-scripts','--pack-destination',out],{cwd:platform});const tar=path.join(out,JSON.parse(packed)[0].filename);
 for(const file of [dmg,tar]){const bytes=await readFile(file);artifacts.push({file:path.basename(file),arch,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});}
 await rm(platform,{recursive:true,force:true});
}
const main=path.join(out,'npm-main');await rm(main,{recursive:true,force:true});await mkdir(main,{recursive:true});await cp(path.join(root,'distribution/npm/cli.cjs'),path.join(main,'cli.cjs'));await chmod(path.join(main,'cli.cjs'),0o755);
await cp(path.join(root,'LICENSE'),path.join(main,'LICENSE'));
// npm chooses one README by filename. Ship only English, with absolute links to GitHub.
const repositoryBase='https://github.com/sufferfml/reset-rune/blob/main/';
const readme=(await readFile(path.join(root,'README.md'),'utf8')).replace(/\]\((?![a-z]+:|#)([^)]+)\)/gi,(_,target)=>`](${repositoryBase}${target})`);
await writeFile(path.join(main,'README.md'),readme);
await writeFile(path.join(main,'package.json'),JSON.stringify({name:'reset-rune',version,description:'Automatically use spare Codex resets before they expire.',license:'MIT',repository:'github:sufferfml/reset-rune',bin:{'reset-rune':'cli.cjs'},os:['darwin'],cpu:['arm64','x64'],engines:{node:'>=22'},files:['LICENSE','README.md','cli.cjs'],optionalDependencies:{'reset-rune-darwin-arm64':version,'reset-rune-darwin-x64':version}},null,2));
const {stdout:packed}=await exec('npm',['pack','--json','--ignore-scripts','--pack-destination',out],{cwd:main});
const tar=path.join(out,JSON.parse(packed)[0].filename), bytes=await readFile(tar);artifacts.push({file:path.basename(tar),bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});
await rm(main,{recursive:true,force:true});
const finalDigests=await digestInputs();const changedInputs=inputPaths.filter(p=>sourceDigests[p]!==finalDigests[p]);
if(changedInputs.length)throw Error('Source changed during packaging: '+changedInputs.join(', '));
await writeFile(path.join(out,'manifest.json'),JSON.stringify({version,signed,notarized:notarize,sourceDigests,artifacts},null,2));
await writeFile(path.join(out,'SHA256SUMS.txt'),artifacts.map(a=>`${a.sha256}  ${a.file}`).join('\n')+'\n');
console.log(JSON.stringify({version,signed,notarized:notarize,artifacts},null,2));
