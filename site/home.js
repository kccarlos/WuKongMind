// WukongMind home page: the demos and reveal-on-scroll. No build step, no dependencies.
// The markup without this file is each demo's finished frame; that is what no-JS and
// reduced motion show. html.anim (set by an inline script in <head> before first paint,
// only without reduced motion) turns the motion on, and this file drives it.
(() => {
  const root = document.documentElement;
  if (!root.classList.contains('anim')) return;
  const labels = document.currentScript.dataset;
  let paused = false;

  // Typed text: every character is already laid out and only appears, in order.
  document.querySelectorAll('.ty').forEach(el => {
    const chars = [...el.textContent];
    el.textContent = '';
    chars.forEach((ch, i) => {
      const span = document.createElement('span');
      span.className = 'c';
      span.style.setProperty('--i', i);
      span.textContent = ch;
      el.append(span);
    });
    el.dataset.split = '';
  });

  // Step n of a stage: classes s1..sn on the stage, .on on its [data-at <= n] children,
  // and each [data-ring="0:idle 2:work 3:done"] ring takes the last state at or before n.
  function setStep(el, n, max) {
    for (let i = 1; i <= max; i++) el.classList.toggle('s' + i, i <= n);
    el.querySelectorAll('[data-at]').forEach(child => child.classList.toggle('on', Number(child.dataset.at) <= n));
    el.querySelectorAll('[data-ring]').forEach(ring => {
      let state = 'idle';
      ring.dataset.ring.split(' ').forEach(pair => {
        const [at, name] = pair.split(':');
        if (Number(at) <= n) state = name;
      });
      if (!ring.classList.contains('is-' + state)) {
        ring.classList.remove('is-idle', 'is-work', 'is-ask', 'is-done');
        ring.classList.add('is-' + state);
      }
    });
  }

  // A stage with data-steps plays step by step while a third of its phone is in view, holds its last
  // frame, then starts again (data-loops, when set, rotates data-loop between plays).
  function makeStage(el) {
    const delays = el.dataset.steps.split(',').map(Number);
    const hold = Number(el.dataset.hold || 3000);
    const loops = Number(el.dataset.loops || 1);
    let step = 0, loop = 0, timer = 0, visible = false;
    el.dataset.loop = 0;
    setStep(el, 0, delays.length);
    function tick() {
      if (step === delays.length) {
        el.classList.add('still');
        step = 0;
        loop = (loop + 1) % loops;
        el.dataset.loop = loop;
        setStep(el, 0, delays.length);
        el.getBoundingClientRect();
        el.classList.remove('still');
      } else {
        setStep(el, ++step, delays.length);
      }
      schedule();
    }
    function schedule() {
      clearTimeout(timer);
      if (visible && !paused) timer = setTimeout(tick, step === delays.length ? hold : delays[step]);
    }
    return { el, watch: el.querySelector('.phone') || el, schedule, show(on) { visible = on; schedule(); } };
  }

  const stages = [...document.querySelectorAll('[data-steps]')].map(makeStage);
  const stageObserver = new IntersectionObserver(entries => {
    entries.forEach(entry => stages.find(s => s.watch === entry.target).show(entry.isIntersecting));
  }, { threshold: 0.35 });
  stages.forEach(stage => stageObserver.observe(stage.watch));

  // One pause button under each looping demo; any of them pauses all of them.
  // The buttons are in the markup (shown only under html.anim), so adding them moves nothing.
  const buttons = [...document.querySelectorAll('.pause')];
  const pauseLabel = buttons[0].textContent;
  buttons.forEach(button => button.addEventListener('click', () => {
    paused = !paused;
    root.classList.toggle('paused', paused);
    buttons.forEach(b => { b.textContent = paused ? labels.play : pauseLabel; });
    stages.forEach(s => s.schedule());
  }));

  // The scroll-driven demo: its step is the number of text steps scrolled into view.
  document.querySelectorAll('.scrolly').forEach(section => {
    const stage = section.querySelector('.st');
    const steps = [...section.querySelectorAll('.step')];
    let queued = false;
    function update() {
      queued = false;
      const line = innerHeight * 0.72;
      const n = steps.filter(step => step.getBoundingClientRect().top < line).length;
      setStep(stage, n, steps.length);
      steps.forEach((step, i) => step.classList.toggle('cur', i === n - 1));
    }
    addEventListener('scroll', () => {
      if (!queued) { queued = true; requestAnimationFrame(update); }
    }, { passive: true });
    addEventListener('resize', update);
    update();
  });

  // Reveal on scroll, once.
  const reveal = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) { entry.target.classList.add('in'); reveal.unobserve(entry.target); }
    });
  }, { rootMargin: '0px 0px -6% 0px' });
  document.querySelectorAll('.rv').forEach(el => reveal.observe(el));

  matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', () => location.reload());
})();
