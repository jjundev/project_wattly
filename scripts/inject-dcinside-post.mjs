import fs from 'node:fs';
import { execSync } from 'node:child_process';

const postContent = fs.readFileSync('docs/promotions/2026-09-07-dcinside-macbook-post.txt', 'utf8');
const title = "대3이 학기중에 빡쳐서 깎은 맥북 시스템/팬/배터리 올인원 툴 (무료)";

const payload = JSON.stringify({
    title,
    content: postContent,
    nickname: "ㅇㅇ",
    password: "1234"
});

// Write injection payload script
const injectionJs = `
(() => {
  const data = ${payload};

  // 1. Head Category (🍏앱 or 📈정보)
  const appHead = document.querySelector('ul.subject_list li[data-no="70"], ul.subject_list li[data-no="40"]');
  if (appHead) {
    appHead.click();
  }

  // 2. Subject
  const subject = document.querySelector('input[name="subject"], #subject');
  if (subject) {
    subject.value = data.title;
    subject.dispatchEvent(new Event('input', { bubbles: true }));
    subject.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // 3. Name & Password
  const name = document.querySelector('input[name="name"], #name');
  if (name && !name.disabled && name.type !== 'hidden') {
    name.value = data.nickname;
    name.dispatchEvent(new Event('input', { bubbles: true }));
    name.dispatchEvent(new Event('change', { bubbles: true }));
  }

  const pw = document.querySelector('input[name="password"], #password');
  if (pw && !pw.disabled && pw.type !== 'hidden') {
    pw.value = data.password;
    pw.dispatchEvent(new Event('input', { bubbles: true }));
    pw.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // 4. Content
  const note = document.querySelector('.note-editable');
  if (note) {
    note.innerHTML = data.content.split('\\n').map(line => '<p>' + (line || '<br>') + '</p>').join('');
    note.dispatchEvent(new Event('input', { bubbles: true }));
  }

  const memo = document.querySelector('textarea[name="memo"], #memo');
  if (memo) {
    memo.value = data.content;
    memo.dispatchEvent(new Event('input', { bubbles: true }));
    memo.dispatchEvent(new Event('change', { bubbles: true }));
  }

  return "SUCCESS";
})()
`;

fs.writeFileSync('/tmp/dc_inject.js', injectionJs);

const result = execSync(`opencli browser dcinside eval "$(cat /tmp/dc_inject.js)"`, { encoding: 'utf8' });
console.log('Injection Result:', result);

// Bring Google Chrome to foreground and activate
execSync(`osascript -e 'tell application "Google Chrome" to activate'`);
console.log('Chrome activated in foreground.');
