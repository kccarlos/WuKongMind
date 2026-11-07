// Forumind for iOS and iPadOS: demos on the home page, the site filter on /sites/, and links. No build step, works from file://.
// Each language is its own page (English source, Chinese copies under zh/ from scripts/site/render_site.py).

// Change these, and only these, when the links are ready.
const APP_STORE_URL = ''; // Empty: the button links to the TestFlight public beta instead.
const TESTFLIGHT_URL = 'https://testflight.apple.com/join/XsfttG4P';

const root = document.documentElement;
const zh = root.lang === 'zh-Hans';

document.querySelectorAll('.store').forEach(button => {
  button.href = APP_STORE_URL || TESTFLIGHT_URL;
  if (APP_STORE_URL) button.textContent = zh ? '前往 App Store' : 'Get it on the App Store';
});

// Old links asked for Chinese with ?lang=zh; it now has its own page.
if (!zh && new URLSearchParams(location.search).get('lang') === 'zh') location.replace(document.querySelector('.lang').href);

// file:// has no directory index: point page links at the file.
if (location.protocol === 'file:') {
  document.querySelectorAll('a[href]').forEach(a => {
    const href = a.getAttribute('href');
    if (!/^([a-z][a-z0-9+.-]*:|#|\/)/i.test(href) && (href.endsWith('/') || href === '..')) a.href = href.replace(/\/?$/, '/') + 'index.html';
  });
}

// Supported sites: filter by category and search. Without JS the whole list shows.
const sites = document.getElementById('sites');
if (sites) {
  const filters = document.querySelector('.filters');
  const search = document.getElementById('site-search');
  const chips = [...document.querySelectorAll('.chip')];
  const empty = document.getElementById('sites-empty');
  let category = 'all';
  const apply = () => {
    const words = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0;
    sites.querySelectorAll('.site').forEach(site => {
      const match = (category === 'all' || site.dataset.categories.split(' ').includes(category)) &&
        words.every(word => site.dataset.keywords.includes(word));
      site.hidden = !match;
      shown += match;
    });
    empty.hidden = shown > 0;
  };
  chips.forEach(chip => chip.addEventListener('click', () => {
    category = chip.dataset.filter;
    chips.forEach(c => c.setAttribute('aria-pressed', String(c === chip)));
    apply();
  }));
  search.addEventListener('input', apply);
  filters.hidden = false;
}

// Demos. html.anim is set by an inline script in <head> before the first
// paint, so nothing that animates is ever drawn in its finished state first.
// Reduced motion and no-JS never get the class and see the finished frames.
const animated = root.classList.contains('anim');

// Streaming text: every word is already laid out and only fades in, in
// reading order. Citations, bullets and heading rules fade with their words.
function splitWords(block) {
  let index = 0;
  const walk = node => {
    for (const child of [...node.childNodes]) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (!child.textContent.trim()) continue;
        const words = child.textContent.match(/[一-鿿，。；：、“”（）]{1,3}|[^一-鿿，。；：、“”（）\s]+\s*|\s+/g) || [];
        const fragment = document.createDocumentFragment();
        words.forEach(word => {
          const span = document.createElement('span');
          span.className = 'w';
          span.style.setProperty('--i', index++);
          span.textContent = word;
          fragment.append(span);
        });
        child.replaceWith(fragment);
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        if (child.matches('.cite, .src')) {
          child.classList.add('w');
          child.style.setProperty('--i', index++);
          continue;
        }
        if (child.matches('li, .h4')) child.style.setProperty('--i', index);
        walk(child);
      }
    }
  };
  walk(block);
  block.dataset.split = '';
}

// Counters (the post count of the whole-thread demo) run from 0 to the value
// in the markup while their step plays.
function runCounters(el, step) {
  el.querySelectorAll(`[data-at="${step}"] [data-count]`).forEach(counter => {
    const target = Number(counter.dataset.count);
    const start = performance.now();
    const frame = now => {
      const t = Math.min(1, (now - start) / 2100);
      counter.textContent = Math.round(target * t).toLocaleString('en-US');
      if (t < 1 && el.classList.contains('live')) counter.raf = requestAnimationFrame(frame);
    };
    cancelAnimationFrame(counter.raf);
    counter.raf = requestAnimationFrame(frame);
  });
}

function resetCounters(el) {
  el.querySelectorAll('[data-count]').forEach(counter => {
    cancelAnimationFrame(counter.raf);
    counter.textContent = '0';
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

  function reset() {
    el.classList.add('still');
    for (let n = 1; n <= delays.length; n++) el.classList.remove('s' + n);
    el.querySelectorAll('.on').forEach(child => child.classList.remove('on'));
    resetCounters(el);
    step = 0;
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
    runCounters(el, step);
    schedule();
  }

  function schedule() {
    if (!visible) return;
    timer = setTimeout(tick, step === delays.length ? hold : delays[step]);
  }

  resetCounters(el);
  return {
    el,
    show() { if (!visible) { visible = true; el.classList.add('live'); schedule(); } },
    hide() { visible = false; clearTimeout(timer); el.classList.remove('live'); }
  };
}

if (animated) {
  document.querySelectorAll('[data-stream]').forEach(splitWords);
  const stages = [...document.querySelectorAll('[data-steps]')].map(makeStage);
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      const stage = stages.find(s => s.el === entry.target);
      if (entry.isIntersecting) stage.show(); else stage.hide();
    });
  }, { threshold: 0.3 });
  stages.forEach(stage => observer.observe(stage.el));
}

matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', () => location.reload());
