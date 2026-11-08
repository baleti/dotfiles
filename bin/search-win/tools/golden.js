// Builds golden.json: runs the web page's own pure functions on a corpus and records the outputs.
// usage: node tools/golden.js <index.html> <history.json> <facets.json> <out golden.json>
const fs = require("fs"), vm = require("vm");
const [html, histF, facF, outF] = process.argv.slice(2);
const lines = fs.readFileSync(html, "utf8").split("\n");
const take = (a, b) => lines.slice(a - 1, b).join("\n");
const hist = JSON.parse(fs.readFileSync(histF, "utf8")).items.slice().reverse();
const facets = JSON.parse(fs.readFileSync(facF, "utf8"));
const src = [take(113, 114), take(120, 123), take(126, 146), take(153, 156), take(365, 365), take(378, 381), take(383, 431), take(434, 437), take(592, 601)].join("\n") +
`
let CURIN="";const $=()=>({value:CURIN});
function setSortQ(Sq,k){const si=sortInfo(Sq),pc=si.explicit?colOfKey(si.key):null;const desc=!(si.explicit&&pc===k&&si.desc);const field=COLS.find(c=>c[0]===k)[2];
  let rest=Sq.replace(/(^|\\s)\\/(?:s|sort)\\/\\S+/g," ").replace(/\\s+/g," ").trim();return (rest?rest+" ":"")+"/s/"+field+(desc?"":"/asc")}
function hlSegs(text,terms){const low=text.toLowerCase(),rg=[];
  for(const t of terms){let f=0,i;while((i=low.indexOf(t,f))>=0){rg.push([i,i+t.length]);f=i+t.length}}
  rg.sort((a,b)=>a[0]-b[0]);let pos=0;const o=[];
  for(const [s,e] of rg){if(e<=pos)continue;const s2=Math.max(s,pos);if(s2>pos)o.push([text.slice(pos,s2),false]);o.push([text.slice(s2,e),true]);pos=e}
  if(pos<text.length)o.push([text.slice(pos),false]);return o}
globalThis.X={cmdSpans,queryTerms,sortInfo,colOfKey,setSortQ,hlSegs,completions,completionsMulti,pathFragment,histMatches,hsize,stime,splitDir,normQ,digits,lightFrom,fuzzy,setIn:v=>{CURIN=v},setFacets:f=>{FACETS=f},setHist:h=>{S.hist=h},isContent:q=>CONTENT.test(q)};
`;
const ctx = vm.createContext({ console, S: { hist }, matchMedia: () => ({}) });
vm.runInContext("var S={hist:[]};" + src, ctx);
const X = ctx.X; X.setFacets(facets); X.setHist(hist);
// corpus
const base = ["", " ", "a", "sample minutes", "/fts beta design //mime pdf", "/fts", "/f", "/s", "/s/", "/s/si", "/s/size/", "/s/size/d", "/g/", "/g/dm/", "/g/dm/s/", "/g/dm/s/size/", "/g/pf/", "/g/dm/w", "//", "//p", "//path", "//path ", "//path gd", "//dm", "//dm ", "//dm 20", "//ext ", "//ext p", "//mime ", "//size ", "//size >", "/clip", "/clip ", "/clip br", "!//mime image", "! /fts", "!/fts", "\"a b\" //name", "//name foo bar", "a||b c", "\"a||b\" c", "/face daniel", "/sort/size,name/asc x", "x /s/date-modified/asc y", "x /s/date-modified y /s/size", "/show-fts-rvt /fts a", "ÄÖÜ straße", "  lead", "trail  ", "a\tb", "/s/date", "/s/date,pa", "/group/", "/group/dm/s", "/hide", "/show-", "//path a b", "//path a//mime pdf", "//path~", "x//path y", "//pathx", "//path\tz"];
const qs = new Set(base);
for (const h of hist) { qs.add(h); for (let i = 1; i < h.length && qs.size < 6000; i += (h.length > 40 ? 3 : 1)) qs.add(h.slice(0, i)); qs.add(h + " "); qs.add(h + " /"); qs.add("/fts " + h); }
const Q = [...qs].slice(0, 6000);
const recs = [];
const add = (fn, args, out) => recs.push({ fn, args, out });
const types = ["cmdSpans", "queryTerms", "sortInfo", "normQ", "pathFragment", "isContent"];
for (const q of Q) {
  for (const f of types) add(f, [q], X[f](q));
  X.setIn(q);
  const c = X.completions(q); add("completions", [q], c);
  add("histMatches", [q], X.histMatches());
  const terms = X.queryTerms(q); add("hlSegs", ["Sample Minutes 2024 Beta design.pdf", terms], X.hlSegs("Sample Minutes 2024 Beta design.pdf", terms));
  for (const col of ["name", "path", "size", "pages", "date"]) add("setSortQ", [q, col], X.setSortQ(q, col));
  const ms = q.lastIndexOf(" ") + 1; add("completionsMulti", [q + " a", ms], X.completionsMulti(q + " a", ms));
  add("completionsMulti", [q, null], X.completionsMulti(q, null));
}
for (const k of ["name", "path", "size", "date", "date-modified", "extension", "pages", "d", "x", "", "dep"]) add("colOfKey", [k], X.colOfKey(k));
for (const n of [0, 1, 1023, 1024, 1025, 1536, 2047, 10240, 1048575, 1048576, 123456789, 5e9, 2.5e12, 1e15, 999, 1126, 1177, 1.5 * 1024 * 1024 * 1024]) { add("hsize", [n], X.hsize(n)); add("digits", [n], X.digits(n)); }
for (const t of ["2026-11-07T13:39:16", "2026-11-07T13:39:16.123456", "2026-11-07", "", "T", "x T y"]) add("stime", [t], X.stime(t));
for (const p of ["/a/b/c.txt", "/c.txt", "c.txt", "", "/", "a/", "https://x/y#/a/b"]) add("splitDir", [p], X.splitDir(p));
for (const [a, b] of [["abc", "ac"], ["abc", "AC"], ["abc", "ca"], ["", ""], ["a", ""]]) add("fuzzy", [a, b], X.fuzzy(a, b));
for (const bg of ["#1f1b16", "#1a1c1e", "#000000", "#ffffff", "#336699", "#ff0000"]) for (const ac of ["#ffb957", "#99cbff", "#808080", "#00ff00"]) add("lightFrom", [{ bg, accent: ac, text: "#fff", dim: "#fff", border: "#fff", error: "#fff" }], X.lightFrom({ bg, accent: ac }));
fs.writeFileSync(outF, JSON.stringify({ facets, hist, recs }));
console.log("golden records:", recs.length);
