const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const child = require('node:child_process');
process.env.PYTHONUTF8 = '1';
const ts = require(process.env.TYPESCRIPT_MODULE || 'typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
function moduleFrom(name) {
  if (cache.has(name)) return cache.get(name);
  const file = path.join(root,'entry/src/main/ets/mihomo',name+'.ets');
  const source = fs.readFileSync(file,'utf8');
  const code = ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
  const output = {exports:{}};
  const context = vm.createContext({module:output,exports:output.exports,console,require:(id)=>id.startsWith('./')?moduleFrom(id.slice(2)): {}});
  new vm.Script(code,{filename:file}).runInContext(context);
  cache.set(name,output.exports); return output.exports;
}
const {buildMihomoConfig} = moduleFrom('ConfigBuilder');
const {groupNodes,withAppStrategies} = moduleFrom('ProxyStrategies');
const {SubscriptionLoader} = moduleFrom('SubscriptionLoader');
const nodes = [
 {name:'A',type:'socks5',lines:['- name: A','  type: socks5','  server: localhost','  port: 1080']},
 {name:'B',type:'socks5',lines:['- name: B','  type: socks5','  server: localhost','  port: 1081']}
];
const groups = [
 {name:'Manual',type:'select',proxies:['A','B','Cycle'],lines:['- name: Manual','  type: select','  proxies:','    - A','    - B','    - Cycle']},
 {name:'Cycle',type:'select',proxies:['Manual','A'],lines:['- name: Cycle','  type: select','  proxies:','    - Manual','    - A']}
];
assert.equal(groupNodes(groups[0],groups,nodes).length,2,'recursive groups must terminate and deduplicate');
const base = {nodes,groups,rules:[{raw:'DOMAIN-SUFFIX,example.com,Manual'},{raw:'DOMAIN,localhost,DIRECT'},{raw:'GEOIP,CN,DIRECT'},{raw:'MATCH,Manual'}],ruleProviders:[],rulesDir:'/tmp/rules',selectedNode:'B',selectedGroup:'',mixedPort:7890,controllerSecret:'test',groupSelections:[{subscriptionId:'x',group:'Manual',node:'B'}]};
for(const input of [base,{...base,groups:[],rules:[],selectedNode:'missing'},{...base,selectedNode:'',selectedGroup:'Manual'}]){
 const yaml=buildMihomoConfig(input);
 const result=child.spawnSync('python',['-c','import sys,json,yaml; print(json.dumps(yaml.safe_load(sys.stdin.read()),ensure_ascii=True))'],{input:yaml,encoding:'utf8'});
 assert.equal(result.status,0,result.stderr);
 const cfg=JSON.parse(result.stdout);
 const route=cfg['proxy-groups'][0];
 assert.equal(route.type,'select');
 assert.equal(route.proxies[0], input.selectedGroup|| (input.selectedNode==='B'?'B':'A'));
 assert(cfg.rules.every(rule=>!rule.startsWith('GEOIP,')));
 assert(cfg.rules.some(rule=>rule==='MATCH,'+route.name));
 assert(!cfg.rules.some(rule=>rule.includes('"'+route.name+'"')),'rule targets must not carry YAML quotes');
 if(input.groups.length) assert.equal(cfg['proxy-groups'].find(g=>g.name==='Manual').proxies[0],'B');
 const reparsed=SubscriptionLoader.parseGroups(yaml);
 assert.equal(reparsed.length,cfg['proxy-groups'].length,'generated groups must round trip through parser');
}
// Real cached fixture is read locally; only counts are printed.
const fixture=path.join(root,'.perf/subscription_raw.txt');
if(fs.existsSync(fixture)){
 const text=fs.readFileSync(fixture,'utf8');
 const parsedNodes=SubscriptionLoader.parseProxies(text);
 const parsedGroups=SubscriptionLoader.parseGroups(text);
 assert(parsedNodes.length>0);
 const yaml=buildMihomoConfig({...base,nodes:parsedNodes,groups:parsedGroups,rules:SubscriptionLoader.parseRules(text),ruleProviders:SubscriptionLoader.parseRuleProviders(text),groupSelections:[]});
 const result=child.spawnSync('python',['-c','import sys,yaml; c=yaml.safe_load(sys.stdin.read()); print(len(c["proxies"]),len(c["proxy-groups"]))'],{input:yaml,encoding:'utf8'});
 assert.equal(result.status,0,result.stderr);
 console.log('Cached fixture node/group counts:',result.stdout.trim());
}
console.log('PASS: config routes, YAML, selection restore, group recursion, parser round trip');
