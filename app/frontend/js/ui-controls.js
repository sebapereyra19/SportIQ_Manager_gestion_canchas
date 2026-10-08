/* ═══════════════════════════════════════════════════════════
   Controles propios del sistema: reemplazan <select> y <input type="date">
   nativos por desplegables / calendario con el diseño del panel.
   El elemento nativo queda oculto y sincronizado, así el resto del código
   (value, onchange, innerHTML dinámico) sigue funcionando igual.
═══════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var MESES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
  var DIAS = ['LU','MA','MI','JU','VI','SA','DO'];
  var CHEVRON = '<svg class="ui-chev" width="12" height="8" viewBox="0 0 12 8" aria-hidden="true"><path d="M1 1.5l5 5 5-5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var CAL_ICON = '<svg class="ui-cal-ico" width="16" height="16" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4.5" width="18" height="16" rx="3"/><path d="M3 9.5h18M8 2.5v4M16 2.5v4"/></svg>';

  var pop = null;       // popup abierto
  var popOwner = null;  // trigger que lo abrió
  var popClose = null;

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function iso(y, m, d) { return y + '-' + pad(m + 1) + '-' + pad(d); }
  function parseISO(v) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v || '');
    return m ? { y: +m[1], m: +m[2] - 1, d: +m[3] } : null;
  }

  /* Intercepta .value (y .selectedIndex) para refrescar el trigger cuando el código lo asigna */
  function hookValue(el, sync) {
    var proto = Object.getPrototypeOf(el);
    ['value', 'selectedIndex'].forEach(function (prop) {
      var d = Object.getOwnPropertyDescriptor(proto, prop);
      if (!d || !d.set) return;
      Object.defineProperty(el, prop, {
        configurable: true,
        get: function () { return d.get.call(this); },
        set: function (v) { d.set.call(this, v); sync(); }
      });
    });
  }

  function fire(el) { el.dispatchEvent(new Event('change', { bubbles: true })); }

  /* ───────── Popup base ───────── */
  function closePop() {
    if (!pop) return;
    pop.remove();
    if (popOwner) popOwner.classList.remove('open');
    pop = popOwner = null;
    if (popClose) { document.removeEventListener('mousedown', popClose, true); popClose = null; }
  }

  function openPop(trigger, node) {
    closePop();
    pop = node;
    popOwner = trigger;
    trigger.classList.add('open');
    document.body.appendChild(pop);
    place();
    popClose = function (e) {
      if (pop && !pop.contains(e.target) && !trigger.contains(e.target)) closePop();
    };
    document.addEventListener('mousedown', popClose, true);
    requestAnimationFrame(function () { if (pop) pop.classList.add('show'); });
  }

  function place() {
    if (!pop || !popOwner) return;
    var r = popOwner.getBoundingClientRect();
    var vw = window.innerWidth, vh = window.innerHeight;
    var isCal = pop.classList.contains('ui-cal');
    var w = isCal ? Math.max(290, Math.min(r.width, 330)) : r.width;
    pop.style.width = w + 'px';
    pop.style.minWidth = isCal ? '' : Math.min(r.width, vw - 16) + 'px';
    var left = Math.min(Math.max(8, r.left), vw - w - 8);
    pop.style.left = left + 'px';
    var h = pop.offsetHeight;
    var below = vh - r.bottom - 8, above = r.top - 8;
    if (h > below && above > below) {
      pop.style.top = '';
      pop.style.bottom = (vh - r.top + 6) + 'px';
      pop.style.maxHeight = Math.min(300, above) + 'px';
      pop.classList.add('up');
    } else {
      pop.style.bottom = '';
      pop.style.top = (r.bottom + 6) + 'px';
      pop.style.maxHeight = Math.min(300, below) + 'px';
      pop.classList.remove('up');
    }
  }

  window.addEventListener('resize', place);
  window.addEventListener('scroll', function (e) {
    if (pop && !pop.contains(e.target)) closePop();
  }, true);
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && pop) { closePop(); }
  });

  /* ───────── SELECT ───────── */
  function enhanceSelect(sel) {
    if (sel._ui || sel.multiple) return;
    sel._ui = true;

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = sel.className + ' ui-trigger ui-select';
    if (sel.getAttribute('style')) btn.setAttribute('style', sel.getAttribute('style'));
    sel.classList.add('ui-native');
    sel.tabIndex = -1;
    sel.parentNode.insertBefore(btn, sel.nextSibling);

    function sync() {
      var o = sel.options[sel.selectedIndex];
      var txt = o ? o.textContent.trim() : '';
      var empty = !o || o.value === '';
      btn.innerHTML = '<span class="ui-label' + (empty ? ' placeholder' : '') + '">' + esc(txt || ' ') + '</span>' + CHEVRON;
      btn.disabled = sel.disabled;
    }
    sync();
    hookValue(sel, sync);
    sel.addEventListener('change', sync);
    new MutationObserver(sync).observe(sel, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['disabled'] });

    function choose(i) {
      var changed = sel.selectedIndex !== i;
      sel.selectedIndex = i;
      closePop();
      btn.focus();
      if (changed) fire(sel);
    }

    function open() {
      if (sel.disabled) return;
      var list = document.createElement('div');
      list.className = 'ui-pop ui-list';
      list.setAttribute('role', 'listbox');
      var html = '';
      Array.prototype.forEach.call(sel.options, function (o, i) {
        if (o.hidden) return;
        html += '<button type="button" role="option" class="ui-opt' + (i === sel.selectedIndex ? ' selected' : '') +
          (o.value === '' ? ' placeholder' : '') + '"' + (o.disabled ? ' disabled' : '') + ' data-i="' + i + '">' +
          '<span>' + esc(o.textContent.trim()) + '</span>' +
          '<svg class="ui-check" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></button>';
      });
      list.innerHTML = html || '<div class="ui-empty">Sin opciones</div>';
      list.addEventListener('click', function (e) {
        var b = e.target.closest('.ui-opt');
        if (b && !b.disabled) choose(+b.dataset.i);
      });
      list.addEventListener('keydown', function (e) { listKeys(e, list); });
      openPop(btn, list);
      var cur = list.querySelector('.selected') || list.querySelector('.ui-opt:not([disabled])');
      if (cur) { cur.focus({ preventScroll: true }); cur.scrollIntoView({ block: 'nearest' }); }
    }

    function listKeys(e, list) {
      var opts = Array.prototype.filter.call(list.querySelectorAll('.ui-opt'), function (b) { return !b.disabled; });
      var i = opts.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); (opts[i + 1] || opts[0]).focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); (opts[i - 1] || opts[opts.length - 1]).focus(); }
      else if (e.key === 'Home') { e.preventDefault(); opts[0].focus(); }
      else if (e.key === 'End') { e.preventDefault(); opts[opts.length - 1].focus(); }
      else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePop(); btn.focus(); }
      else if (e.key === 'Tab') { closePop(); }
    }

    btn.addEventListener('click', function () { (pop && popOwner === btn) ? closePop() : open(); });
    btn.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); open(); }
    });
  }

  /* ───────── DATE ───────── */
  function enhanceDate(inp) {
    if (inp._ui) return;
    inp._ui = true;

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = inp.className + ' ui-trigger ui-date';
    if (inp.getAttribute('style')) btn.setAttribute('style', inp.getAttribute('style'));
    inp.classList.add('ui-native');
    inp.tabIndex = -1;
    inp.parentNode.insertBefore(btn, inp.nextSibling);

    function sync() {
      var p = parseISO(inp.value);
      var txt = p ? pad(p.d) + '/' + pad(p.m + 1) + '/' + p.y : 'dd/mm/aaaa';
      btn.innerHTML = '<span class="ui-label' + (p ? '' : ' placeholder') + '">' + txt + '</span>' + CAL_ICON;
      btn.disabled = inp.disabled;
    }
    sync();
    hookValue(inp, sync);
    inp.addEventListener('change', sync);
    new MutationObserver(sync).observe(inp, { attributes: true, attributeFilter: ['disabled'] });

    function pick(v) {
      var changed = inp.value !== v;
      inp.value = v;
      closePop();
      btn.focus();
      if (changed) fire(inp);
    }

    function open() {
      if (inp.disabled) return;
      var now = new Date();
      var today = { y: now.getFullYear(), m: now.getMonth(), d: now.getDate() };
      var sel = parseISO(inp.value);
      var view = { y: (sel || today).y, m: (sel || today).m };
      var min = inp.min || '', max = inp.max || '';

      var box = document.createElement('div');
      box.className = 'ui-pop ui-cal';

      function render() {
        var first = new Date(view.y, view.m, 1);
        var offset = (first.getDay() + 6) % 7;
        var start = new Date(view.y, view.m, 1 - offset);
        var h = '<div class="ui-cal-head"><span class="ui-cal-title">' + MESES[view.m] + ' de ' + view.y + '</span>' +
          '<span class="ui-cal-nav">' +
          '<button type="button" class="ui-cal-btn" data-nav="-1" aria-label="Mes anterior"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg></button>' +
          '<button type="button" class="ui-cal-btn" data-nav="1" aria-label="Mes siguiente"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg></button>' +
          '</span></div><div class="ui-cal-grid">';
        DIAS.forEach(function (d) { h += '<span class="ui-cal-dow">' + d + '</span>'; });
        for (var i = 0; i < 42; i++) {
          var dt = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
          var v = iso(dt.getFullYear(), dt.getMonth(), dt.getDate());
          var cls = 'ui-day';
          if (dt.getMonth() !== view.m) cls += ' out';
          if (v === iso(today.y, today.m, today.d)) cls += ' today';
          if (sel && v === iso(sel.y, sel.m, sel.d)) cls += ' selected';
          var dis = (min && v < min) || (max && v > max);
          h += '<button type="button" class="' + cls + '" data-v="' + v + '"' + (dis ? ' disabled' : '') + '>' + dt.getDate() + '</button>';
        }
        h += '</div><div class="ui-cal-foot"><button type="button" class="ui-cal-link" data-act="clear">Borrar</button>' +
          '<button type="button" class="ui-cal-link" data-act="today">Hoy</button></div>';
        box.innerHTML = h;
      }
      render();

      box.addEventListener('click', function (e) {
        var n = e.target.closest('[data-nav]');
        if (n) {
          view.m += +n.dataset.nav;
          if (view.m < 0) { view.m = 11; view.y--; }
          if (view.m > 11) { view.m = 0; view.y++; }
          render(); place();
          return;
        }
        var d = e.target.closest('.ui-day');
        if (d && !d.disabled) { pick(d.dataset.v); return; }
        var a = e.target.closest('[data-act]');
        if (a) pick(a.dataset.act === 'clear' ? '' : iso(today.y, today.m, today.d));
      });
      openPop(btn, box);
    }

    btn.addEventListener('click', function () { (pop && popOwner === btn) ? closePop() : open(); });
    btn.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') { e.preventDefault(); open(); }
    });
  }

  /* ───────── Descubrimiento (incluye contenido que se inyecta luego) ───────── */
  function scan(root) {
    if (!root || root.nodeType !== 1) return;
    if (root.matches && root.matches('select.form-select')) enhanceSelect(root);
    if (root.matches && root.matches('input[type="date"]')) enhanceDate(root);
    if (!root.querySelectorAll) return;
    Array.prototype.forEach.call(root.querySelectorAll('select.form-select'), enhanceSelect);
    Array.prototype.forEach.call(root.querySelectorAll('input[type="date"]'), enhanceDate);
  }

  function init() {
    scan(document.body);
    new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        Array.prototype.forEach.call(m.addedNodes, scan);
      });
    }).observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
