/// 局域网上传页内嵌全部资源；固定地址直接显示文件选择，不需要账号或传输码。
const wifiUploadPage =
    r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>阅读 · Wi-Fi 上传</title>
<style>
:root{color-scheme:dark;font:16px/1.6 system-ui;background:#161616;color:#ccc}*{box-sizing:border-box}body{margin:0;padding:40px 20px}main{max-width:720px;margin:auto}h1{font-size:30px;margin:0}h2{font-size:20px;margin:0}p{color:#999}.card{background:#222;border:1px solid #383838;border-radius:20px;padding:24px;margin:24px 0}input,button,select{font:inherit;border-radius:12px;padding:12px 16px;border:1px solid #666;background:#2a2a2a;color:#ddd}button{background:#c6b79e;color:#25211b;cursor:pointer;font-weight:600}button:disabled{opacity:.5;cursor:wait}#drop{border:2px dashed #666;border-radius:16px;padding:36px 16px;text-align:center;margin:20px 0}#drop.over{border-color:#c6b79e;background:#36312a}#files{max-width:100%;margin-top:12px}progress{width:100%;accent-color:#c6b79e;height:12px}li{padding:8px 0;overflow-wrap:anywhere}#message{color:#c6b79e;white-space:pre-line}.row{display:flex;gap:12px;flex-wrap:wrap;align-items:center}
</style><main><h1>阅读 · Wi-Fi 上传</h1><p>把电脑上的书籍和字体，直接传到当前阅读器。</p>
<section class="card"><div class="row"><h2>选择文件</h2><select id="kind" aria-label="上传类型"><option value="auto">自动识别书籍 / 字体</option><option value="book">书籍</option><option value="font">字体</option></select></div>
<div id="drop">拖入多个文件，或点击选择<br><input type="file" id="files" multiple accept=".txt,.epub,.mobi,.azw,.azw3,.html,.htm,.ttf,.otf"></div>
<button id="send">开始上传</button><p>书籍支持 TXT、EPUB、MOBI、AZW、HTML；字体支持 TTF / OTF。请保持阅读器传输页在前台。</p>
<progress id="progress" max="100" value="0"></progress><ul id="results"></ul></section><p id="message" role="status">已连接，可以选择文件。</p></main>
<script>
const $=id=>document.getElementById(id);let selected=[],sending=false;
$('files').onchange=()=>{if(!sending){selected=Array.from($('files').files);$('message').textContent=`已选择 ${selected.length} 个文件`;}};
$('drop').ondragover=e=>{e.preventDefault();$('drop').classList.add('over');};$('drop').ondragleave=()=>{$('drop').classList.remove('over');};
$('drop').ondrop=e=>{e.preventDefault();$('drop').classList.remove('over');if(!sending){selected=Array.from(e.dataTransfer.files);$('message').textContent=`已选择 ${selected.length} 个文件`;}};
function upload(file,kind){return new Promise((resolve,reject)=>{const xhr=new XMLHttpRequest();xhr.open('POST',`/upload?kind=${kind}&name=${encodeURIComponent(file.name)}`);xhr.setRequestHeader('Content-Type','application/octet-stream');xhr.upload.onprogress=e=>{if(e.lengthComputable)$('progress').value=e.loaded/e.total*100;};xhr.onload=()=>{let data;try{data=JSON.parse(xhr.responseText);}catch(_){reject(Error('阅读器响应异常'));return;}xhr.status>=200&&xhr.status<300?resolve(data):reject(Error(data.error||'导入失败'));};xhr.onerror=()=>reject(Error('连接中断，请确认阅读器传输页仍在前台'));xhr.send(file);});}
$('send').onclick=async()=>{if(sending||!selected.length){$('message').textContent='请先选择文件';return;}sending=true;$('send').disabled=true;$('files').disabled=true;$('kind').disabled=true;
for(let i=0;i<selected.length;i++){const file=selected[i],row=document.createElement('li');row.textContent=`${file.name} · 正在上传`;$('results').appendChild(row);$('message').textContent=`上传 ${i+1} / ${selected.length}`;$('progress').value=0;
const kind=$('kind').value==='auto'?(/\.(ttf|otf)$/i.test(file.name)?'font':'book'):$('kind').value;
try{if(kind==='book'&&file.size>64*1024*1024)throw Error('电子书不能超过 64 MB');const result=await upload(file,kind);row.textContent=`✓ ${file.name} · ${result.name} 已导入`;}catch(error){row.textContent=`× ${file.name} · ${error.message}`;}}
sending=false;$('send').disabled=false;$('files').disabled=false;$('kind').disabled=false;$('message').textContent='上传完成，请查看各文件结果。字体可在阅读器设置中切换。';};
</script></html>''';
