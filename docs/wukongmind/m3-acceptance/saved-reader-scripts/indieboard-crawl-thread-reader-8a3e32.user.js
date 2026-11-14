// ==UserScript==
// @name IndieBoard crawl thread reader
// @match http://127.0.0.1:8765/crawl/*
// @run-at document-end
// @version 1
// @wukong-id indieboard-crawl-thread-reader-8a3e32
// @wukong-environment isolated
// @wukong-enabled true
// @wukong-source agent
// @wukong-prompt Save your thread-reading logic for this site as a userscript with script_save that stores this page's marker text in window.__marker and exposes window.__readThread(). Confirm it is saved.
// @wukong-created-at 2026-11-14T08:38:27.466Z
// @wukong-updated-at 2026-11-14T08:38:27.466Z
// ==/UserScript==
(function () {
  function readMarker() {
    var el = document.querySelector('p.marker');
    return el ? el.textContent.trim() : null;
  }
  function readThread() {
    var posts = Array.prototype.map.call(
      document.querySelectorAll('article.post'),
      function (a, i) {
        var h = a.querySelector('h3');
        var p = a.querySelector('p');
        return {
          number: i + 1,
          author: h ? h.textContent.replace(/^Reply\s+\d+\s+by\s+/i, '').trim() : null,
          body: p ? p.textContent.trim() : ''
        };
      }
    );
    return {
      title: (document.querySelector('h1') || {}).textContent || document.title,
      marker: readMarker(),
      url: location.href,
      posts: posts
    };
  }
  window.__marker = readMarker();
  window.__readThread = readThread;
})();