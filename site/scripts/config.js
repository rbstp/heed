// The bar: workspaces track the block in view, the toggle module switches the
// cursorline, the clock ticks, and the version module asks GitHub.
(function () {
  'use strict';

  // The cursorline starts on, whatever the markup around this script says.
  document.body.classList.add('follow');

  const links = Array.from(document.querySelectorAll('#workspaces a'));
  const blocks = links
    .map((a) => document.getElementById(a.getAttribute('href').slice(1)))
    .filter(Boolean);

  function update() {
    const line = 96;
    let pick = null;
    for (const b of blocks) {
      const r = b.getBoundingClientRect();
      if (r.top <= line) pick = b;
    }
    links.forEach((a) => {
      if (pick && a.getAttribute('href') === '#' + pick.id) a.setAttribute('aria-current', 'true');
      else a.removeAttribute('aria-current');
    });
  }
  window.addEventListener('scroll', update, { passive: true });
  window.addEventListener('resize', update);
  update();

  const toggle = document.getElementById('ffm-toggle');
  const label = document.getElementById('ffm-label');
  if (toggle) {
    toggle.addEventListener('click', () => {
      const on = toggle.getAttribute('aria-pressed') !== 'true';
      toggle.setAttribute('aria-pressed', String(on));
      toggle.title = on ? 'Cursorline follows the pointer. Click to turn it off.' : 'Cursorline is off. Click to turn it on.';
      document.body.classList.toggle('follow', on);
      if (label) label.textContent = 'follow_mouse = ' + (on ? '1' : '0');
    });
  }

  document.querySelectorAll('.copy').forEach((btn) => {
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.copy || '');
        btn.textContent = 'copied';
        btn.classList.add('copied');
        setTimeout(() => { btn.textContent = 'copy'; btn.classList.remove('copied'); }, 1400);
      } catch (err) { /* clipboard unavailable */ }
    });
  });

  const clock = document.getElementById('clock');
  if (clock) {
    const tick = () => {
      clock.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    };
    tick();
    setInterval(tick, 15000);
  }

  const version = document.getElementById('version');
  if (version && window.fetch) {
    fetch('https://api.github.com/repos/rbstp/heed/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
      .then((r) => (r.ok ? r.json() : null))
      .then((rel) => {
        if (rel && rel.tag_name) {
          version.textContent = rel.tag_name;
          version.href = rel.html_url;
        }
      })
      .catch(() => { /* the static version stands */ });
  }
})();
