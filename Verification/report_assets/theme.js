/* Theme switch, copied from the isentropic.com.br site (theme.js): applies the
   saved (or system) theme before paint and wires [data-theme-toggle]. */
(function () {
  var KEY = 'isentropic-theme';
  var root = document.documentElement;
  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  var system = window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  root.setAttribute('data-theme', saved === 'dark' || saved === 'light' ? saved : system);

  if (window.__isentropicThemeBound) return;
  window.__isentropicThemeBound = true;
  document.addEventListener('click', function (e) {
    var btn = e.target && e.target.closest && e.target.closest('[data-theme-toggle]');
    if (!btn) return;
    var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem(KEY, next); } catch (err) {}
  });
})();
