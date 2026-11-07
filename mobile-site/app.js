// Forumind for iOS and iPadOS: promotional page, and the language switch of its privacy and support pages. No build step, works from file://.

// Change these, and only these, when the links are ready.
const APP_STORE_URL = ''; // Empty: the button links to the TestFlight public beta instead.
const TESTFLIGHT_URL = 'https://testflight.apple.com/join/XsfttG4P';
// Relative to this site; file:// has no directory index, so it names the file.
const INDEX = location.protocol === 'file:' ? 'index.html' : '';
const PRIVACY_URL = 'privacy/' + INDEX;
const SUPPORT_URL = 'support/' + INDEX;

const LABEL_STORE = { en: 'Get it on the App Store', zh: '前往 App Store' };
const LABEL_BETA = { en: 'Join the beta on TestFlight', zh: '通过 TestFlight 加入测试版' };
const META = {
  en: {
    title: 'Forumind for iPhone and iPad: AI reading companion for forums and blogs',
    description: 'Summaries that cite the post, answers with sources, a daily digest you can listen to, and live voice. For Discourse forums, WordPress sites and Hacker News.'
  },
  zh: {
    title: 'Forumind iPhone 与 iPad 版：论坛和博客的 AI 阅读伴侣',
    description: '摘要标注楼层号，回答附带来源，每日摘要还能当播客听，也能直接开口问。支持 Discourse 论坛、WordPress 网站和 Hacker News。'
  }
};

// The privacy and support pages share this file: they set the title in a <title data-zh> instead.
const META_BY_PAGE = !document.body.dataset.page;
const root = document.documentElement;
const motion = matchMedia('(prefers-reduced-motion: reduce)');
const animated = !motion.matches && 'IntersectionObserver' in window;
const stages = [];

function storedLang() {
  try { return localStorage.getItem('forumind-lang'); } catch { return null; }
}

function initialLang() {
  const asked = new URLSearchParams(location.search).get('lang');
  if (asked === 'zh' || asked === 'en') return asked;
  const saved = storedLang();
  if (saved === 'zh' || saved === 'en') return saved;
  return (navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en';
}

// Links and store button.
document.querySelectorAll('[data-link=privacy]').forEach(a => { a.href = PRIVACY_URL; });
document.querySelectorAll('[data-link=support]').forEach(a => { a.href = SUPPORT_URL; });

function renderStore(lang) {
  document.querySelectorAll('.store').forEach(button => {
    button.href = APP_STORE_URL || TESTFLIGHT_URL;
    button.textContent = (APP_STORE_URL ? LABEL_STORE : LABEL_BETA)[lang];
  });
}

// Language. English lives in the markup; each element carries its Chinese in data-zh.
function setLang(lang) {
  root.lang = lang === 'zh' ? 'zh-Hans' : 'en';
  document.querySelectorAll('[data-zh]').forEach(el => {
    if (el.dataset.en === undefined) el.dataset.en = el.innerHTML;
    el.innerHTML = lang === 'zh' ? el.dataset.zh : el.dataset.en;
  });
  document.querySelectorAll('[data-zh-label]').forEach(el => {
    if (el.dataset.enLabel === undefined) el.dataset.enLabel = el.getAttribute('aria-label');
    el.setAttribute('aria-label', lang === 'zh' ? el.dataset.zhLabel : el.dataset.enLabel);
  });
  if (META_BY_PAGE) {
    document.title = META[lang].title;
    document.querySelector('meta[name=description]').content = META[lang].description;
  }
  const button = document.getElementById('lang');
  button.textContent = lang === 'zh' ? 'English' : '中文';
  button.lang = lang === 'zh' ? 'en' : 'zh-Hans';
  button.setAttribute('aria-label', lang === 'zh' ? 'Switch to English' : '切换到简体中文');
  renderStore(lang);
  if (animated) document.querySelectorAll('[data-stream]').forEach(splitWords);
  stages.forEach(stage => stage.restart());
}

// Streaming text: every word is already laid out and only fades in.
function splitWords(block) {
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  let index = 0;
  nodes.forEach(node => {
    if (!node.textContent.trim() || node.parentElement.closest('.w, .cite')) return;
    const words = node.textContent.match(/[一-鿿，。；：、“”]{1,3}|[^一-鿿，。；：、“”\s]+\s*|\s+/g) || [];
    const fragment = document.createDocumentFragment();
    words.forEach(word => {
      const span = document.createElement('span');
      span.className = 'w';
      span.style.setProperty('--i', index++);
      span.textContent = word;
      fragment.append(span);
    });
    node.replaceWith(fragment);
  });
  block.querySelectorAll('.cite').forEach(cite => {
    cite.classList.add('w');
    cite.style.setProperty('--i', Math.round(index * 0.5));
  });
}

// A stage plays its demo step by step while it is in view. Step n adds class
// sn to the stage and .on to its [data-at=n] children. Its markup without any
// of this is the finished frame, which is what reduced motion and no-JS see.
function makeStage(el) {
  const delays = el.dataset.steps.split(',').map(Number);
  const hold = Number(el.dataset.hold || 3500);
  let step = 0;
  let timer = 0;
  let visible = false;

  function clear() {
    for (let n = 1; n <= delays.length; n++) el.classList.remove('s' + n);
    el.querySelectorAll('.on').forEach(child => child.classList.remove('on'));
    step = 0;
  }

  function reset() {
    el.classList.add('still');
    clear();
    el.getBoundingClientRect();
    el.classList.remove('still', 'out');
  }

  function tick() {
    if (step === delays.length) {
      el.classList.add('out');
      timer = setTimeout(() => { reset(); schedule(); }, 400);
      return;
    }
    step += 1;
    el.classList.add('s' + step);
    el.querySelectorAll(`[data-at="${step}"]`).forEach(child => child.classList.add('on'));
    schedule();
  }

  function schedule() {
    if (!visible) return;
    timer = setTimeout(tick, step === delays.length ? hold : delays[step]);
  }

  el.classList.add('still');
  el.getBoundingClientRect();
  el.classList.remove('still');

  return {
    el,
    show() { if (!visible) { visible = true; el.classList.add('live'); schedule(); } },
    hide() { visible = false; clearTimeout(timer); el.classList.remove('live'); },
    restart() { clearTimeout(timer); el.classList.remove('out'); reset(); schedule(); }
  };
}

let lang = initialLang();
setLang(lang);

if (animated) {
  root.classList.add('anim');
  document.querySelectorAll('[data-steps]').forEach(el => stages.push(makeStage(el)));
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      const stage = stages.find(s => s.el === entry.target);
      if (entry.isIntersecting) stage.show(); else stage.hide();
    });
  }, { threshold: 0.3 });
  stages.forEach(stage => observer.observe(stage.el));
}

motion.addEventListener('change', () => location.reload());

document.getElementById('lang').addEventListener('click', () => {
  lang = lang === 'zh' ? 'en' : 'zh';
  try { localStorage.setItem('forumind-lang', lang); } catch { /* file:// in some browsers */ }
  setLang(lang);
});
