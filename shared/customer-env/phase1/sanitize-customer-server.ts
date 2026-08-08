#!/usr/bin/env bun
import { readFileSync, writeFileSync } from "node:fs";

const path=process.argv[2];
if (!path) throw new Error("usage: sanitize-customer-server.ts BUNDLED_SERVER");
let text=readFileSync(path,"utf8");
const replacements:[RegExp,string][]=[
  [/\/home\/oldrabbit/g,"/var/lib/channellab-mvp"],
  [/\.claude-bots/g,"channellab-runtime"],
  [/\boldrabbit\b/gi,"customer_owner"],
  [/\bbthare\b/gi,"customer_owner"],
  [/\blaotu\b/gi,"customer_admin"],
  [/\b1050312492\b/g,"customer_chat"],
  [/\bassist-anya\b/gi,"customer_assistant"],
  [/\bcaijie-zhuchu\b/gi,"customer_role"],
  [/\bron-assistant\b/gi,"customer_role"],
  [/\blilai-fengfeng\b/gi,"customer_role"],
  [/\bnicky-zhanglinghe\b/gi,"customer_role"],
  [/\bchltao\b/gi,"customer_role"],
  [/\bwes-buddy\b/gi,"customer_role"],
  [/\b33-huizhang\b/gi,"customer_role"],
  [/\banya\b/gi,"customer_assistant"],
  [/\bnicky\b/gi,"customer_member"],
  [/\bcarrot\b/gi,"customer_member"],
  [/\blilai\b/gi,"customer_member"],
  [/\bthreethree\b/gi,"customer_member"],
  [/\bwes\b/gi,"customer_member"],
  [/\bron\b/gi,"customer_member"],
];
for (const [pattern,value] of replacements) text=text.replace(pattern,value);
writeFileSync(path,text);
const forbidden=/oldrabbit|\.claude-bots|bthare|laotu|1050312492|assist-anya|caijie-zhuchu|ron-assistant|lilai-fengfeng|nicky-zhanglinghe|chltao|wes-buddy|33-huizhang|\banya\b|\bnicky\b|\bcarrot\b|\blilai\b|\bthreethree\b|\bwes\b|\bron\b/i;
const hit=text.match(forbidden);
if (hit) throw new Error(`CUSTOMER_SERVER_INTERNAL_TOKEN=${hit[0]}`);
console.log("BUILT_SERVER_INTERNAL_HITS=0");
