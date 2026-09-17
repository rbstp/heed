// Theme toggle, copy buttons, the outline's current section, and the latest
// release in the kicker.
(function () {
  'use strict';

  const root = document.documentElement;
  const toggle = document.getElementById('theme-toggle');
  const icon = document.getElementById('theme-icon');

  function paintIcon() {
    const use = icon && icon.querySelector('use');
    if (use) use.setAttribute('href', root.getAttribute('data-theme') === 'light' ? '#icon-moon' : '#icon-sun');
  }
  paintIcon();
  if (toggle) {
    toggle.addEventListener('click', () => {
      const next = root.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem('theme', next); } catch (e) { /* ignore */ }
      paintIcon();
    });
  }

  document.querySelectorAll('.copy').forEach((btn) => {
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.copy || '');
        btn.textContent = 'Copied';
        btn.classList.add('copied');
        setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1400);
      } catch (err) { /* clipboard unavailable */ }
    });
  });

  // Outline: the heading nearest the top of the viewport is current.
  const links = Array.from(document.querySelectorAll('#toc-list a'));
  const headings = links
    .map((a) => document.getElementById(a.getAttribute('href').slice(1)))
    .filter(Boolean);
  if (headings.length && 'IntersectionObserver' in window) {
    let current = null;
    const setCurrent = (id) => {
      if (id === current) return;
      current = id;
      links.forEach((a) => {
        if (a.getAttribute('href') === '#' + id) a.setAttribute('aria-current', 'true');
        else a.removeAttribute('aria-current');
      });
    };
    const update = () => {
      const line = 120;
      let pick = headings[0];
      for (const h of headings) {
        if (h.getBoundingClientRect().top <= line) pick = h;
      }
      setCurrent(pick.id);
    };
    const io = new IntersectionObserver(update, { rootMargin: '-100px 0px -60% 0px' });
    headings.forEach((h) => io.observe(h));
    window.addEventListener('scroll', update, { passive: true });
    update();
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
