// The page behaves like Heed: the tile under the pointer takes focus, the
// focus shortcuts step between tiles, and holding the modifier numbers them.
// The timings are Heed's defaults: entryMotionPx 6, handoverSettleMs 300,
// windowNumbersDelayMs 100.
(function () {
  'use strict';

  const tiles = Array.from(document.querySelectorAll('.tile'));
  const workspaces = document.getElementById('workspaces');
  const toggle = document.getElementById('ffm-toggle');
  const state = document.getElementById('ffm-state');
  const mac = /Mac|iPhone|iPad/.test(navigator.platform) || /Mac OS/.test(navigator.userAgent);

  let followMouse = true;
  let focused = -1;
  // Focus that arrived by keyboard stays until the pointer settles elsewhere.
  let held = false;

  // Number the tiles and build the workspace bar from them.
  tiles.forEach((tile, i) => {
    const n = i + 1;
    tile.dataset.number = String(n);
    const title = tile.querySelector('.tile-title');
    if (title) title.dataset.number = String(n);
    const overlay = document.createElement('div');
    overlay.className = 'tile-number';
    overlay.setAttribute('aria-hidden', 'true');
    overlay.innerHTML = '<span>' + n + '</span>';
    tile.appendChild(overlay);
    if (workspaces && n <= 9) {
      const a = document.createElement('a');
      a.href = '#' + tile.id;
      a.textContent = String(n);
      a.title = (title ? title.textContent.trim() : tile.id);
      a.addEventListener('click', (e) => {
        e.preventDefault();
        focusTile(i, 'key');
      });
      workspaces.appendChild(a);
    }
  });

  function focusTile(i, source) {
    if (i < 0 || i >= tiles.length) return;
    if (i === focused && source !== 'key') return;
    tiles.forEach((t, j) => t.classList.toggle('focused', j === i));
    if (workspaces) {
      Array.from(workspaces.children).forEach((a, j) => {
        if (j === i) a.setAttribute('aria-current', 'true');
        else a.removeAttribute('aria-current');
      });
    }
    focused = i;
    if (source === 'key') {
      held = true;
      tiles[i].focus({ preventScroll: true });
      tiles[i].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      try { history.replaceState(null, '', '#' + tiles[i].id); } catch (err) { /* sandboxed */ }
    }
  }

  // --- follow_mouse ---------------------------------------------------------
  const ENTRY_MOTION = 6;
  const HANDOVER_SETTLE = 300;
  let entry = null;      // where the pointer entered the current tile
  let settle = 0;        // timer for the handover guard

  tiles.forEach((tile, i) => {
    tile.addEventListener('pointerenter', (e) => {
      entry = { x: e.clientX, y: e.clientY, i };
      clearTimeout(settle);
    });
    tile.addEventListener('pointerleave', () => {
      if (entry && entry.i === i) entry = null;
      clearTimeout(settle);
    });
    tile.addEventListener('pointermove', (e) => {
      if (!followMouse || !entry || entry.i !== i || i === focused) return;
      // Small movement does not count as settling on another window.
      if (Math.hypot(e.clientX - entry.x, e.clientY - entry.y) < ENTRY_MOTION) return;
      if (held) {
        clearTimeout(settle);
        settle = setTimeout(() => { held = false; focusTile(i, 'pointer'); }, HANDOVER_SETTLE);
      } else {
        focusTile(i, 'pointer');
      }
    });
  });

  function setFollowMouse(on) {
    followMouse = on;
    toggle.setAttribute('aria-pressed', String(on));
    toggle.title = on
      ? 'Focus follows mouse is on. Click to turn it off for this page.'
      : 'Focus follows mouse is off. Click to turn it on.';
    if (state) {
      state.dataset.on = String(on);
      state.textContent = 'focus follows mouse: ' + (on ? 'on' : 'off');
    }
  }
  toggle.addEventListener('click', () => setFollowMouse(!followMouse));

  // --- movefocus --------------------------------------------------------------
  const NUMBERS_DELAY = 100;
  let numbersTimer = 0;

  function modifierHeld(e) {
    return mac ? (e.ctrlKey && e.metaKey && !e.altKey) : (e.ctrlKey && e.altKey && !e.metaKey);
  }
  function onlyModifiers(e) {
    return ['Control', 'Meta', 'Alt', 'Shift'].includes(e.key);
  }

  document.addEventListener('keydown', (e) => {
    if (!modifierHeld(e)) return;
    if (onlyModifiers(e)) {
      if (!numbersTimer) {
        numbersTimer = setTimeout(() => document.body.classList.add('numbering'), NUMBERS_DELAY);
      }
      return;
    }
    let handled = true;
    if (e.key === 'ArrowRight') focusTile(Math.min(tiles.length - 1, Math.max(focused, 0) + 1), 'key');
    else if (e.key === 'ArrowLeft') focusTile(Math.max(0, focused - 1), 'key');
    else if (e.key === 'ArrowDown') focusTile(neighbour(0, 1), 'key');
    else if (e.key === 'ArrowUp') focusTile(neighbour(0, -1), 'key');
    else if (/^[1-9]$/.test(e.key)) focusTile(Number(e.key) - 1, 'key');
    else if (e.key.toLowerCase() === 'h') setFollowMouse(!followMouse);
    else handled = false;
    if (handled) {
      e.preventDefault();
      // A shortcut typed at speed does not flash the numbers.
      clearTimeout(numbersTimer);
      numbersTimer = 0;
      document.body.classList.remove('numbering');
    }
  });

  function releaseNumbers() {
    clearTimeout(numbersTimer);
    numbersTimer = 0;
    document.body.classList.remove('numbering');
  }
  document.addEventListener('keyup', (e) => { if (onlyModifiers(e)) releaseNumbers(); });
  window.addEventListener('blur', releaseNumbers);

  // Directional: nearest tile in that direction, a shared column winning over a
  // closer one that does not share it, and the edge a dead end.
  function neighbour(dx, dy) {
    const from = tiles[Math.max(focused, 0)].getBoundingClientRect();
    let best = -1;
    let bestScore = Infinity;
    tiles.forEach((t, i) => {
      if (i === focused) return;
      const r = t.getBoundingClientRect();
      const ahead = dy ? (r.top - from.top) * dy : (r.left - from.left) * dx;
      if (ahead <= 1) return;
      const overlap = dy
        ? Math.min(r.right, from.right) - Math.max(r.left, from.left)
        : Math.min(r.bottom, from.bottom) - Math.max(r.top, from.top);
      const score = ahead + (overlap > 0 ? 0 : 100000);
      if (score < bestScore) { bestScore = score; best = i; }
    });
    return best === -1 ? focused : best;
  }

  // --- the rest -------------------------------------------------------------
  const hint = document.getElementById('hint');
  if (hint && !mac) {
    hint.querySelectorAll('.keys').forEach((k) => {
      const kbds = k.querySelectorAll('kbd');
      if (kbds[1] && kbds[1].textContent === '⌘') kbds[1].textContent = 'Alt';
      if (kbds[0] && kbds[0].textContent === '⌃') kbds[0].textContent = 'Ctrl';
    });
  }

  document.querySelectorAll('.copy').forEach((btn) => {
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.copy || '');
        btn.textContent = 'copied';
        btn.classList.add('copied');
        setTimeout(() => { btn.textContent = 'copy'; btn.classList.remove('copied'); }, 1400);
      } catch (err) { /* clipboard unavailable: nothing to do */ }
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
      .catch(() => { /* offline or rate limited: the static version stands */ });
  }

  // Start on the tile named in the URL, or the first one: a focus shortcut with
  // nothing to step from steps from the window under the pointer.
  const start = tiles.findIndex((t) => '#' + t.id === location.hash);
  focusTile(start >= 0 ? start : 0, 'pointer');
})();
