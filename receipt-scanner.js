(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  let enginePromise = null;
  let scanning = false;
  const setMessage = (message, error = false) => {
    const el = $('receiptScanMessage');
    if (!el) return;
    el.textContent = message;
    el.style.color = error ? '#e09a8f' : '';
  };
  const loadEngine = () => {
    if (window.Tesseract) return Promise.resolve(window.Tesseract);
    if (enginePromise) return enginePromise;
    enginePromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = 'https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js';
      script.async = true;
      script.onload = () => window.Tesseract ? resolve(window.Tesseract) : reject(new Error('تعذر تحميل محرك قراءة الريسيت'));
      script.onerror = () => reject(new Error('تعذر تحميل محرك القراءة. تحقق من الإنترنت وحاول مرة أخرى.'));
      document.head.appendChild(script);
    });
    return enginePromise;
  };
  const normalizeDigits = value => String(value || '').replace(/[٠-٩۰-۹]/g, d => {
    const a = '٠١٢٣٤٥٦٧٨٩', b = '۰۱۲۳۴۵۶۷۸۹';
    return String(a.indexOf(d) >= 0 ? a.indexOf(d) : b.indexOf(d));
  });
  const fillIfUseful = (id, value) => {
    const el = $(id);
    if (el && value && (!el.value.trim() || id === 'deliveryOrderItems')) el.value = value.trim();
  };
  const extractData = raw => {
    const text = normalizeDigits(raw).replace(/\r/g, '');
    const lines = text.split('\n').map(x => x.trim()).filter(Boolean);
    const phoneMatch = text.match(/(?:\+?20\s*)?0?1[0125][0-9\s-]{8,12}/);
    const money = text.match(/(?:الإجمالي|الاجمالي|المجموع|total|grand\s*total|net\s*total)[^\d]{0,18}([\d,]+(?:\.\d{1,2})?)/i);
    const amountMatches = [...text.matchAll(/(?:ج\.?م|EGP|LE|L\.E\.?|جنيه)?\s*([0-9][0-9,]*(?:\.\d{1,2})?)\s*(?:ج\.?م|EGP|LE|L\.E\.?|جنيه)/gi)];
    let customer = '';
    let address = '';
    const customerLine = lines.find(x => /(اسم العميل|العميل|customer\s*name|name)\s*[:：-]/i.test(x));
    if (customerLine) customer = customerLine.replace(/.*?(?:اسم العميل|العميل|customer\s*name|name)\s*[:：-]\s*/i, '').trim();
    const addressIndex = lines.findIndex(x => /(العنوان|عنوان التوصيل|address|delivery\s*to)\s*[:：-]?/i.test(x));
    if (addressIndex >= 0) {
      address = lines.slice(addressIndex, Math.min(lines.length, addressIndex + 3)).join(' ').replace(/^(?:العنوان|عنوان التوصيل|address|delivery\s*to)\s*[:：-]?\s*/i, '').trim();
    }
    if (!customer && phoneMatch) {
      const pi = lines.findIndex(x => x.includes(phoneMatch[0]));
      if (pi > 0 && !/(بيتزا|pizza|king|morin|فاتورة|receipt|order)/i.test(lines[pi - 1])) customer = lines[pi - 1].slice(0, 90);
    }
    const total = money ? money[1].replace(/,/g, '') : (amountMatches.length ? amountMatches[amountMatches.length - 1][1].replace(/,/g, '') : '');
    const itemLines = lines.filter(x =>
      x.length > 2 &&
      !/(بيتزا كينج|pizza king|morin|فاتورة|receipt|invoice|tel|phone|mobile|العنوان|address|customer|اسم العميل|الإجمالي|الاجمالي|total|subtotal|tax|ضريبة|خصم|discount|delivery fee|التوصيل|شكرا|thank)/i.test(x) &&
      /[\p{L}]/u.test(x) &&
      /\d/.test(x)
    );
    return {
      customer,
      phone: phoneMatch ? phoneMatch[0].replace(/[\s-]/g, '') : '',
      address,
      total,
      items: itemLines.slice(0, 18).join('\n')
    };
  };
  const runScan = async file => {
    if (!file || scanning) return;
    if (!/^image\//.test(file.type)) {
      setMessage('اختار صورة JPG أو PNG أو WEBP للمسح. يمكن إرفاق PDF للحفظ فقط.', true);
      return;
    }
    scanning = true;
    const buttons = ['receiptCameraBtn', 'receiptScanBtn'];
    buttons.forEach(id => { if ($(id)) $(id).disabled = true; });
    const progress = $('receiptScanProgress');
    if (progress) progress.style.width = '4%';
    setMessage('جاري تجهيز الماسح...');
    try {
      const Tesseract = await loadEngine();
      const result = await Tesseract.recognize(file, 'ara+eng', {
        logger: info => {
          if (progress && info.status === 'recognizing text') progress.style.width = Math.max(5, Math.round((info.progress || 0) * 100)) + '%';
          if (info.status) setMessage(info.status === 'recognizing text' ? 'جاري قراءة بيانات الريسيت...' : 'جاري تجهيز محرك القراءة...');
        }
      });
      const raw = result?.data?.text || '';
      if (!raw.trim()) throw new Error('لم يتم العثور على نص واضح في الصورة.');
      const data = extractData(raw);
      fillIfUseful('deliveryOrderCustomer', data.customer);
      fillIfUseful('deliveryOrderPhone', data.phone);
      fillIfUseful('deliveryOrderAddress', data.address);
      fillIfUseful('deliveryOrderItems', data.items);
      fillIfUseful('deliveryOrderTotal', data.total);
      const details = [];
      if (data.customer) details.push('اسم العميل');
      if (data.phone) details.push('الهاتف');
      if (data.address) details.push('العنوان');
      if (data.items) details.push('الأصناف');
      if (data.total) details.push('الإجمالي');
      setMessage(details.length
        ? 'تم استخراج: ' + details.join('، ') + '. راجع البيانات وعدّلها قبل حفظ الأوردر.'
        : 'تمت قراءة الصورة، لكن لم أتعرف تلقائيًا على الحقول. يمكنك مراجعة النص وإدخال البيانات يدويًا.');
      const rawBox = $('receiptScanRaw');
      if (rawBox) {
        rawBox.value = raw;
        rawBox.classList.remove('hidden');
      }
    } catch (error) {
      setMessage(error.message || 'تعذر قراءة الريسيت. جرّب صورة أوضح أو أدخل البيانات يدويًا.', true);
    } finally {
      scanning = false;
      buttons.forEach(id => { if ($(id)) $(id).disabled = false; });
      if (progress) progress.style.width = '100%';
    }
  };
  document.addEventListener('DOMContentLoaded', () => {
    const camera = $('deliveryOrderReceiptCamera');
    const upload = $('deliveryOrderReceipt');
    const cameraBtn = $('receiptCameraBtn');
    const scanBtn = $('receiptScanBtn');
    if (cameraBtn && camera) cameraBtn.addEventListener('click', () => camera.click());
    if (scanBtn && upload) scanBtn.addEventListener('click', () => upload.click());
    if (camera) camera.addEventListener('change', () => {
      const file = camera.files && camera.files[0];
      if (!file) return;
      try {
        const transfer = new DataTransfer();
        transfer.items.add(file);
        if (upload) upload.files = transfer.files;
      } catch (_) {}
      runScan(file);
    });
    if (upload) upload.addEventListener('change', () => runScan(upload.files && upload.files[0]));
  });
})();