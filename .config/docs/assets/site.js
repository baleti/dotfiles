/* dotfiles docs - client-side nav + search
   Hand-written source asset (not generated). */
(function () {
  "use strict";

  // ---- mobile sidebar toggle ----
  var toggle = document.getElementById("navtoggle");
  var sidebar = document.getElementById("sidebar");
  if (toggle && sidebar) {
    toggle.addEventListener("click", function () { sidebar.classList.toggle("open"); });
    sidebar.addEventListener("click", function (e) {
      if (e.target.tagName === "A") sidebar.classList.remove("open");
    });
  }

  // ---- scrollspy for the on-this-page toc ----
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
  if (tocLinks.length) {
    var targets = tocLinks
      .map(function (a) { return document.getElementById(decodeURIComponent(a.hash.slice(1))); })
      .filter(Boolean);
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (!en.isIntersecting) return;
        tocLinks.forEach(function (a) { a.classList.remove("active"); });
        var active = tocLinks.filter(function (a) {
          return decodeURIComponent(a.hash.slice(1)) === en.target.id;
        })[0];
        if (active) active.classList.add("active");
      });
    }, { rootMargin: "-70px 0px -70% 0px" });
    targets.forEach(function (t) { spy.observe(t); });
  }

  // ---- search ----
  var input = document.getElementById("search");
  var panel = document.getElementById("searchpanel");
  var index = window.SEARCH_INDEX || [];
  if (!input || !panel) return;

  function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
  function escHtml(s) {
    return s.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function snippet(text, terms) {
    var lc = text.toLowerCase();
    var at = -1;
    for (var i = 0; i < terms.length; i++) {
      var p = lc.indexOf(terms[i]);
      if (p !== -1 && (at === -1 || p < at)) at = p;
    }
    if (at === -1) at = 0;
    var start = Math.max(0, at - 60);
    var frag = (start > 0 ? "…" : "") + text.slice(start, start + 180).trim() + "…";
    frag = escHtml(frag);
    terms.forEach(function (t) {
      if (!t) return;
      frag = frag.replace(new RegExp("(" + esc(escHtml(t)) + ")", "gi"), "<mark>$1</mark>");
    });
    return frag;
  }

  function score(entry, terms) {
    var hay = (entry.title + " " + entry.headings.map(function (h) { return h.text; }).join(" ") +
      " " + entry.text).toLowerCase();
    var s = 0;
    for (var i = 0; i < terms.length; i++) {
      var t = terms[i];
      if (!t) continue;
      if (hay.indexOf(t) === -1) return 0;               // AND across terms
      if (entry.title.toLowerCase().indexOf(t) !== -1) s += 8;
      entry.headings.forEach(function (h) {
        if (h.text.toLowerCase().indexOf(t) !== -1) s += 4;
      });
      var m = hay.match(new RegExp(esc(t), "g"));
      s += m ? m.length : 0;
    }
    return s;
  }

  function bestAnchor(entry, terms) {
    var best = null;
    entry.headings.forEach(function (h) {
      var lc = h.text.toLowerCase();
      for (var i = 0; i < terms.length; i++) {
        if (terms[i] && lc.indexOf(terms[i]) !== -1) { best = h; return; }
      }
    });
    return best;
  }

  function render(q) {
    var terms = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!terms.length) { panel.hidden = true; panel.innerHTML = ""; return; }
    var hits = index
      .map(function (e) { return { e: e, s: score(e, terms) }; })
      .filter(function (x) { return x.s > 0; })
      .sort(function (a, b) { return b.s - a.s; })
      .slice(0, 30);

    if (!hits.length) {
      panel.innerHTML = '<p class="sr-empty">No matches for “' + escHtml(q) + '”.</p>';
      panel.hidden = false;
      return;
    }
    var html = "";
    hits.forEach(function (x) {
      var e = x.e;
      var a = bestAnchor(e, terms);
      var url = e.url + (a ? "#" + a.id : "");
      html += '<a class="sr-hit" href="' + url + '">' +
        '<span class="sr-page">' + escHtml(e.title) + '</span>' +
        '<span class="sr-head">' + escHtml(a ? a.text : e.title) + '</span>' +
        '<span class="sr-ctx">' + snippet(e.text, terms) + '</span>' +
        '</a>';
    });
    panel.innerHTML = html;
    panel.hidden = false;
  }

  input.addEventListener("input", function () { render(input.value); });
  input.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { input.value = ""; render(""); input.blur(); }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "/" && document.activeElement !== input &&
        !/^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName)) {
      e.preventDefault(); input.focus();
    }
  });
  panel.addEventListener("click", function (e) {
    if (e.target.closest(".sr-hit")) { panel.hidden = true; input.value = ""; }
  });
})();
