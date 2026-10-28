// usage: node render.js out.jpg '{"label":"Oct 26 - Nov 1","touches":21525,"kids":10,"sessions":40,"total":71000}'
const {chromium}=require('playwright'); const path=require('path');
(async()=>{const [out,json]=process.argv.slice(2), d=JSON.parse(json);
const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1080,height:1920}});
await p.goto('file://'+path.join(__dirname,'tt.html')+'?'+new URLSearchParams(d)); await p.waitForTimeout(800);
await p.screenshot({path:out,type:'jpeg',quality:92}); await b.close(); console.log('wrote',out);})();
