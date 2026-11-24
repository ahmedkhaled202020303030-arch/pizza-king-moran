(() => {
'use strict';
const $ = id => document.getElementById(id);
const suppliers=['المصنع - نموذج 1','المصنع - نموذج 2','دومتي','جومو','كورنر'];
let invItems=[], invDocs=[], invLines=[], invOcrBusy=false;
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const msg=(s,bad=false)=>{const e=$('inventoryMessage');if(e){e.textContent=s;e.style.color=bad?'#ff9b91':'';}};
const currentBranch=()=>currentManagerProfile?.branch||'';
const selectedBranch=()=>isBranchManager?currentBranch():($('inventoryBranch').value||'');
const fillSelect=(el,values,first)=>{if(!el)return;el.innerHTML=(first?'<option value="">'+esc(first)+'</option>':'')+values.map(x=>'<option>'+esc(x)+'</option>').join('');};
function linesFromText(raw){
 const out=[];
 String(raw||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean).forEach(line=>{
  let m=line.match(/^(.+?)[\t;,|]+\s*([0-9٠-٩۰-۹]+(?:[.,][0-9٠-٩۰-۹]+)?)\s*([^\d]*)$/);
  if(!m)m=line.match(/^(.+?)\s{2,}([0-9٠-٩۰-۹]+(?:[.,][0-9٠-٩۰-۹]+)?)\s*([^\d]*)$/);
  if(!m)m=line.match(/^(.+?)\s+([0-9٠-٩۰-۹]+(?:[.,][0-9٠-٩۰-۹]+)?)\s*$/);
  if(m){const digits=m[2].replace(/[٠-٩۰-۹]/g,d=>'٠١٢٣٤٥٦٧٨٩'.indexOf(d)>=0?'٠١٢٣٤٥٦٧٨٩'.indexOf(d):'۰۱۲۳۴۵۶۷۸۹'.indexOf(d));out.push({name:m[1].trim().replace(/^[•*-]\s*/,''),qty:Number(digits.replace(',','.')),unit:(m[3]||'').trim()||'وحدة'});}
 });
 return out.filter(x=>x.name&&Number.isFinite(x.qty)&&x.qty>=0);
}
function renderLineEditor(rows){
 $('inventoryLineEditor').innerHTML=rows.map((x,i)=>'<div class="inventory-line"><input data-inv-name="'+i+'" value="'+esc(x.name)+'" placeholder="اسم الصنف"><input data-inv-qty="'+i+'" type="number" min="0" step="0.001" value="'+esc(x.qty)+'" placeholder="الكمية"><input data-inv-unit="'+i+'" value="'+esc(x.unit||'وحدة')+'" placeholder="الوحدة"><button type="button" class="light" data-inv-remove="'+i+'">×</button></div>').join('')||'<p class="muted">لم تتم إضافة أصناف بعد.</p>';
}
function readEditor(){return [...$('inventoryLineEditor').querySelectorAll('[data-inv-name]')].map((e)=>{const i=e.dataset.invName;return {name:e.value.trim(),qty:Number($('inventoryLineEditor').querySelector('[data-inv-qty="'+i+'"]').value),unit:$('inventoryLineEditor').querySelector('[data-inv-unit="'+i+'"]').value.trim()||'وحدة'};}).filter(x=>x.name&&Number.isFinite(x.qty)&&x.qty>=0);}
function addLine(name='',qty='',unit='وحدة'){const a=readEditor();a.push({name,qty,unit});renderLineEditor(a);}
async function loadInventory(){
 if(!db||!currentUser)return;
 msg('جاري تحميل بيانات المخازن...');
 const [a,b,c]=await Promise.all([
  db.from('inventory_items').select('*').eq('active',true).order('supplier').order('item_name'),
  db.from('inventory_documents').select('*').order('doc_date',{ascending:false}).limit(300),
  db.from('inventory_document_lines').select('*')
 ]);
 const error=a.error||b.error||c.error;
 if(error){msg('تعذر تحميل المخازن. تأكد من تنفيذ inventory_migration.sql في Supabase: '+error.message,true);return;}
 invItems=a.data||[];invDocs=b.data||[];invLines=c.data||[];
 if(isBranchManager){$('inventoryBranch').innerHTML='<option value="'+esc(currentBranch())+'">'+esc(currentBranch())+'</option>';$('inventoryBranch').value=currentBranch();$('inventoryBranch').disabled=true;}
 else {$('inventoryBranch').disabled=false;if(!$('inventoryBranch').querySelector('option[value=""]'))$('inventoryBranch').insertAdjacentHTML('afterbegin','<option value="">كل الفروع — عرض فقط</option>');}
 renderItems();renderHistory();renderReconciliation();msg('تم تحميل بيانات المخازن.');
}
function renderItems(){
 const supplier=$('inventorySupplier').value||suppliers[0];
 const rows=invItems.filter(x=>x.supplier===supplier);
 $('inventoryItemsList').innerHTML=rows.map(x=>'<div class="inventory-item"><strong>'+esc(x.item_name)+'</strong><span>'+esc(x.unit)+'</span><button type="button" class="light" data-item-delete="'+x.id+'">حذف</button></div>').join('')||'<p class="muted">لا توجد أصناف مسجلة لهذا المورد. أضفها يدويًا أو استخرجها من ورقة المورد.</p>';
}
function renderHistory(){
 const supplier=$('inventoryHistorySupplier').value,branch=selectedBranch();
 const docs=invDocs.filter(d=>(!supplier||d.supplier===supplier)&&(!branch||d.branch===branch));
 $('inventoryHistory').innerHTML=docs.slice(0,100).map(d=>{const ls=invLines.filter(x=>x.document_id===d.id);return '<article class="panel inventory-history-card"><strong>'+(d.doc_type==='receipt'?'إذن استلام فعلي':'كشف المحاسب')+' · '+esc(d.supplier)+'</strong><div>'+esc(d.branch)+' | '+esc(d.doc_date)+' | '+esc(d.reference_no||'بدون رقم')+'</div><small>'+ls.map(x=>esc(x.item_name)+': '+x.quantity+' '+esc(x.unit)).join(' — ')+'</small></article>';}).join('')||'<p class="muted">لا توجد أذون مسجلة لهذا الاختيار.</p>';
}
function renderReconciliation(){
 const supplier=$('inventoryCompareSupplier').value||suppliers[0],branch=selectedBranch();
 const from=$('inventoryCompareFrom').value,to=$('inventoryCompareTo').value;
 if(!from||!to){$('inventoryCompareTable').innerHTML='<p class="muted">حدد تاريخ البداية والنهاية لعرض المطابقة.</p>';return;}
 if(from>to){$('inventoryCompareTable').innerHTML='<p class="muted">تاريخ البداية لازم يكون قبل تاريخ النهاية أو مساويًا له.</p>';return;}
 const docs=invDocs.filter(d=>d.supplier===supplier&&(!branch||d.branch===branch)&&d.doc_date>=from&&d.doc_date<=to);
 const actual={},account={};
 for(const d of docs){const target=d.doc_type==='receipt'?actual:account;invLines.filter(x=>x.document_id===d.id).forEach(x=>target[x.item_name]=(target[x.item_name]||0)+Number(x.quantity));}
 const names=[...new Set([...Object.keys(actual),...Object.keys(account)])].sort((a,b)=>a.localeCompare(b,'ar'));
 const totals=names.reduce((t,n)=>{t.actual+=actual[n]||0;t.account+=account[n]||0;return t;},{actual:0,account:0});
 const summary='<div class="inventory-item"><strong>الفترة: '+esc(from)+' إلى '+esc(to)+'</strong><span>إجمالي الاستلام: '+totals.actual+'</span><span>إجمالي كشف المحاسب: '+totals.account+'</span></div>';
 $('inventoryCompareTable').innerHTML=names.length?summary+'<div class="inventory-table-wrap"><table><thead><tr><th>الصنف</th><th>إجمالي الاستلام الفعلي</th><th>إجمالي كشف المحاسب</th><th>الفرق (فعلي - محاسب)</th><th>الحالة</th></tr></thead><tbody>'+names.map(n=>{const a=actual[n]||0,b=account[n]||0,d=a-b;return '<tr><td>'+esc(n)+'</td><td>'+a+'</td><td>'+b+'</td><td>'+d+'</td><td>'+(d===0?'متطابق':d<0?'عجز':'زيادة')+'</td></tr>';}).join('')+'</tbody></table></div>':'<p class="muted">لا توجد مستندات لهذا المورد والفرع داخل الفترة المحددة.</p>';
}
async function saveDocument(){
 const rows=readEditor(),type=$('inventoryDocType').value,supplier=$('inventorySupplier').value,branch=selectedBranch(),date=$('inventoryDate').value;
 if(!branch||!date||!rows.length){msg('اختَر فرعًا محددًا (لا يمكن الحفظ على اختيار كل الفروع)، وحدد التاريخ وأدخل صنفًا واحدًا على الأقل.',true);return;}
 if(rows.some(x=>!x.name||!Number.isFinite(x.qty)||x.qty<0)){msg('راجع أسماء الأصناف والكميات.',true);return;}
 const btn=$('inventorySaveBtn');btn.disabled=true;
 try{
  const h=await db.from('inventory_documents').insert({doc_type:type,supplier,branch,doc_date:date,reference_no:$('inventoryReference').value.trim()||null,notes:$('inventoryNotes').value.trim()||null,created_by:currentUser.id}).select().single();
  if(h.error)throw h.error;
  const ins=await db.from('inventory_document_lines').insert(rows.map(x=>({document_id:h.data.id,item_name:x.name,quantity:x.qty,unit:x.unit})));
  if(ins.error){await db.from('inventory_documents').delete().eq('id',h.data.id);throw ins.error;}
  msg('تم حفظ '+(type==='receipt'?'إذن الاستلام':'كشف المحاسب')+' بنجاح.');
  $('inventoryReference').value='';$('inventoryNotes').value='';renderLineEditor([]);await loadInventory();
 }catch(e){msg('تعذر الحفظ: '+e.message,true);}finally{btn.disabled=false;}
}
async function scanInventory(file){
 if(!file||invOcrBusy)return;
 if(!file.type.startsWith('image/')){msg('المسح الضوئي يدعم الصور. يمكن إدخال بيانات PDF يدويًا بعد الاطلاع عليه.',true);return;}
 invOcrBusy=true;$('inventoryScanBtn').disabled=true;msg('جاري قراءة الورقة بالعربية والإنجليزية...');
 try{
  if(!window.Tesseract)throw new Error('محرك المسح غير متاح حاليًا. أعد تحميل الصفحة.');
  const result=await Tesseract.recognize(file,'ara+eng',{logger:x=>{if(x.status==='recognizing text')msg('جاري استخراج النص... '+Math.round((x.progress||0)*100)+'%');}});
  const raw=result?.data?.text||'';$('inventoryOcrText').value=raw;
  const parsed=linesFromText(raw);
  if(parsed.length){renderLineEditor([...readEditor(),...parsed]);msg('استخرجت '+parsed.length+' سطرًا مبدئيًا. راجع كل صنف وكمية قبل الحفظ.');}
  else msg('تمت قراءة الورقة لكن لم أتعرف تلقائيًا على نمط الصنف والكمية. راجع النص وأدخل البيانات يدويًا.');
 }catch(e){msg('تعذر المسح: '+e.message,true);}finally{invOcrBusy=false;$('inventoryScanBtn').disabled=false;}
}
function openInventory(){
 ['customersView','staffDirectoryView','attendanceView','deliveryRepsView','deliveryRepsMapView','deliveryOrdersView','tripsView'].forEach(id=>$(id)?.classList.add('hidden'));
 $('inventoryView').classList.remove('hidden');
 document.querySelectorAll('#appMainNav button').forEach(x=>x.classList.remove('active'));
 $('inventoryNavBtn').classList.add('active');setAppMenu(false);
 loadInventory();
}
document.addEventListener('DOMContentLoaded',()=>{
 if(!$('inventoryNavBtn'))return;
 fillSelect($('inventorySupplier'),suppliers);
 fillSelect($('inventoryHistorySupplier'),suppliers,'كل الموردين');
 fillSelect($('inventoryCompareSupplier'),suppliers);
 $('inventoryDate').value=new Date().toLocaleDateString('en-CA',{timeZone:'Africa/Cairo'});
 const today=new Date().toLocaleDateString('en-CA',{timeZone:'Africa/Cairo'});$('inventoryCompareTo').value=today;$('inventoryCompareFrom').value=today.slice(0,8)+'01';
 fillSelect($('inventoryBranch'),branches||[]);
 $('inventorySupplier').addEventListener('change',renderItems);
 $('inventoryHistorySupplier').addEventListener('change',renderHistory);
 $('inventoryCompareSupplier').addEventListener('change',renderReconciliation);
 $('inventoryCompareApplyBtn').addEventListener('click',renderReconciliation);
 $('inventoryBranch').addEventListener('change',()=>{renderHistory();renderReconciliation();});
 $('inventoryAddItemBtn').addEventListener('click',async()=>{const name=$('inventoryNewItem').value.trim(),supplier=$('inventorySupplier').value;if(!name)return msg('اكتب اسم الصنف أولًا.',true);const q=await db.from('inventory_items').insert({supplier,item_name:name,unit:$('inventoryNewUnit').value.trim()||'وحدة'});if(q.error)msg('تعذر إضافة الصنف: '+q.error.message,true);else{$('inventoryNewItem').value='';$('inventoryNewUnit').value='';await loadInventory();}});
 $('inventoryItemsList').addEventListener('click',async e=>{const b=e.target.closest('[data-item-delete]');if(!b||!confirm('حذف الصنف من القائمة؟'))return;const q=await db.from('inventory_items').delete().eq('id',b.dataset.itemDelete);if(q.error)msg(q.error.message,true);else await loadInventory();});
 $('inventoryAddLineBtn').addEventListener('click',()=>addLine());
 $('inventoryLineEditor').addEventListener('click',e=>{const b=e.target.closest('[data-inv-remove]');if(!b)return;const a=readEditor();a.splice(Number(b.dataset.invRemove),1);renderLineEditor(a);});
 $('inventorySaveBtn').addEventListener('click',saveDocument);
 $('inventoryScanBtn').addEventListener('click',()=>$('inventoryCameraInput').click());
 $('inventoryUploadBtn').addEventListener('click',()=>$('inventoryFileInput').click());
 ['inventoryCameraInput','inventoryFileInput'].forEach(id=>$(id).addEventListener('change',e=>scanInventory(e.target.files?.[0])));
 $('inventoryRefreshBtn').addEventListener('click',loadInventory);
 $('inventoryNavBtn').addEventListener('click',openInventory);
 $('inventoryDocType').addEventListener('change',()=>{$('inventoryDocTypeLabel').textContent=$('inventoryDocType').value==='receipt'?'إذن استلام فعلي':'كشف المحاسب';});
});
window.addEventListener('pkm:inventory-open',loadInventory);
})();