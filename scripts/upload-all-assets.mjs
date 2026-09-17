import fs from 'node:fs';
import { execSync } from 'node:child_process';

const ASSETS = [
    { id: 'img-placeholder-1', file: 'docs/assets/demo-overview.gif', name: 'demo-overview.gif', mime: 'image/gif' },
    { id: 'img-placeholder-2', file: 'docs/assets/menubar-live.gif', name: 'menubar-live.gif', mime: 'image/gif' },
    { id: 'img-placeholder-3', file: 'docs/assets/popover-mode-a-stacked.png', name: 'popover-mode-a-stacked.png', mime: 'image/png' },
    { id: 'img-placeholder-4', file: 'docs/assets/expand-power.png', name: 'expand-power.png', mime: 'image/png' },
    { id: 'img-placeholder-5', file: 'docs/assets/expand-cpu.png', name: 'expand-cpu.png', mime: 'image/png' },
    { id: 'img-placeholder-6', file: 'docs/assets/settings-fan-curve.png', name: 'settings-fan-curve.png', mime: 'image/png' },
    { id: 'img-placeholder-7', file: 'docs/assets/settings-battery.png', name: 'settings-battery.png', mime: 'image/png' },
];

const TITLE = "[Wattly] 맥북갤 피드백 반영해서 대규모 업데이트했습니다 (모니터링/팬조절/배터리)";
const NICKNAME = "ㅇㅇ";
const PASSWORD = "1234";

function evalInBrowser(code) {
    fs.writeFileSync('/tmp/eval_run.js', code);
    return execSync('opencli browser dcinside eval "$(cat /tmp/eval_run.js)"', { encoding: 'utf8', maxBuffer: 20 * 1024 * 1024 });
}

console.log('1. Setting up fresh post form fields and content...');

// Read base text
let postText = fs.readFileSync('docs/promotions/2026-09-07-dcinside-macbook-post.txt', 'utf8');

postText = postText
    .replace('[이미지 1: 전체 UI 구동 시연 고화질 움짤 (demo-overview.gif)]', '<p id="img-placeholder-1">[이미지 1 로딩중...]</p>')
    .replace('[이미지 2: 메뉴바 라이브 모션 (menubar-live.gif)]', '<p id="img-placeholder-2">[이미지 2 로딩중...]</p>')
    .replace('[이미지 3: 팝오버 3단 레이아웃 (popover-mode-a-stacked.png)]', '<p id="img-placeholder-3">[이미지 3 로딩중...]</p>')
    .replace('[이미지 4: 프로세서 전력 SoC 분해 (expand-power.png)]', '<p id="img-placeholder-4">[이미지 4 로딩중...]</p>')
    .replace('[이미지 5: CPU 코어 클러스터 & 주파수 게이지 (expand-cpu.png)]', '<p id="img-placeholder-5">[이미지 5 로딩중...]</p>')
    .replace('[이미지 6: 스마트 팬 커브 에디터 (settings-fan-curve.png)]', '<p id="img-placeholder-6">[이미지 6 로딩중...]</p>')
    .replace('[이미지 7: 배터리 관리 및 충전 제어 설정 (settings-battery.png)]', '<p id="img-placeholder-7">[이미지 7 로딩중...]</p>');

const formattedHtml = postText.split('\n').map(line => {
    if (line.startsWith('<p id="img-placeholder')) return line;
    return '<p>' + (line || '<br>') + '</p>';
}).join('');

const setupJs = `
(() => {
  window.attachments = [];
  window.__fileChunks = [];

  // 1. Head Category (🍏앱)
  const appHead = document.querySelector('ul.subject_list li[data-no="70"], ul.subject_list li[data-no="40"]');
  if (appHead) {
    appHead.click();
  }

  // 2. Title
  const subject = document.querySelector('input[name="subject"], #subject');
  if (subject) {
    subject.value = ${JSON.stringify(TITLE)};
    subject.dispatchEvent(new Event('input', { bubbles: true }));
    subject.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // 3. Name & Password (유동닉 ㅇㅇ)
  const name = document.querySelector('input[name="name"], #name');
  if (name && !name.disabled && name.type !== 'hidden') {
    name.value = ${JSON.stringify(NICKNAME)};
    name.dispatchEvent(new Event('input', { bubbles: true }));
    name.dispatchEvent(new Event('change', { bubbles: true }));
  }

  const pw = document.querySelector('input[name="password"], #password');
  if (pw && !pw.disabled && pw.type !== 'hidden') {
    pw.value = ${JSON.stringify(PASSWORD)};
    pw.dispatchEvent(new Event('input', { bubbles: true }));
    pw.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // 4. Reset editable content via Summernote API
  if (typeof $('#memo').summernote === 'function') {
    $('#memo').summernote('code', ${JSON.stringify(formattedHtml)});
  } else {
    const note = document.querySelector('.note-editable');
    if (note) note.innerHTML = ${JSON.stringify(formattedHtml)};
  }

  // 5. Register upload helper with data-tempno
  window.__uploadFileFromBase64 = function(base64, filename, mimeType, placeholderId) {
    return new Promise((resolve) => {
      try {
        const byteCharacters = atob(base64);
        const byteNumbers = new Array(byteCharacters.length);
        for (let i = 0; i < byteCharacters.length; i++) {
          byteNumbers[i] = byteCharacters.charCodeAt(i);
        }
        const byteArray = new Uint8Array(byteNumbers);
        const file = new File([byteArray], filename, { type: mimeType });

        const originalAttach = window.attach;
        let done = false;
        window.attach = function(data) {
          window.attach = originalAttach;
          done = true;

          // Important: DCInside requires data-tempno on every uploaded img element!
          const el = document.getElementById(placeholderId);
          if (el) {
            el.outerHTML = '<p style="text-align: center; margin: 18px 0;"><img src="' + data.imageurl + '" data-tempno="' + data.file_temp_no + '" class="tx-daum-image" style="max-width: 100%; border-radius: 4px;" alt="' + filename + '"></p>';
          }

          if (!window.attachments) window.attachments = [];
          window.attachments.push(data);
          $('#upload_status').val('Y');

          resolve(JSON.stringify({ success: true, filename, tempno: data.file_temp_no }));
        };

        window.imageUploader(file);

        setTimeout(() => {
          if (!done) {
            window.attach = originalAttach;
            resolve(JSON.stringify({ success: false, reason: "timeout" }));
          }
        }, 30000);
      } catch (err) {
        resolve(JSON.stringify({ success: false, error: err.message }));
      }
    });
  };

  return "SETUP_DONE";
})()
`;

evalInBrowser(setupJs);
console.log('Setup completed.');

// Process each asset
for (let i = 0; i < ASSETS.length; i++) {
    const asset = ASSETS[i];
    console.log(`Uploading asset ${i + 1}/${ASSETS.length}: ${asset.name}...`);
    const buffer = fs.readFileSync(asset.file);
    const base64 = buffer.toString('base64');

    if (base64.length < 700000) {
        const uploadJs = `window.__uploadFileFromBase64("${base64}", "${asset.name}", "${asset.mime}", "${asset.id}")`;
        const res = evalInBrowser(uploadJs);
        console.log(`  Uploaded ${asset.name}: ${res.trim()}`);
    } else {
        console.log(`  Large file detected (${(buffer.length / 1024 / 1024).toFixed(2)} MB), chunking...`);
        evalInBrowser('window.__fileChunks = []; "RESET"');
        const chunkSize = 400000;
        const totalChunks = Math.ceil(base64.length / chunkSize);
        for (let c = 0; c < totalChunks; c++) {
            const chunk = base64.slice(c * chunkSize, (c + 1) * chunkSize);
            evalInBrowser(`window.__fileChunks.push("${chunk}"); "CHUNK_${c + 1}/${totalChunks}"`);
            process.stdout.write(`\r  Sending chunks: ${c + 1}/${totalChunks}`);
        }
        console.log('\n  All chunks sent. Executing upload...');
        const finishJs = `
        (() => {
          const fullBase64 = window.__fileChunks.join("");
          window.__fileChunks = [];
          return window.__uploadFileFromBase64(fullBase64, "${asset.name}", "${asset.mime}", "${asset.id}");
        })()
        `;
        const res = evalInBrowser(finishJs);
        console.log(`  Uploaded ${asset.name}: ${res.trim()}`);
    }
}

// Final sync to summernote and memo
console.log('Finalizing editor synchronization...');
evalInBrowser(`
(() => {
  const note = document.querySelector('.note-editable');
  if (note && typeof $('#memo').summernote === 'function') {
    $('#memo').val(note.innerHTML);
  }
  return "SYNC_DONE";
})()
`);

// Also copy title and text to macOS clipboard
execSync(`echo "${TITLE}" | pbcopy`);
console.log('Title copied to macOS clipboard.');

// Bring Chrome to front
execSync("osascript -e 'tell application \"Google Chrome\" to activate'");
console.log('Chrome activated in foreground.');
