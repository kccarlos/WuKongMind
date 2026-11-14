The 25-page fixture forum for M3 acceptance check 1 (design-m3.md). A non-Discourse
thread: `page-01.html` to `page-25.html`, each with one unique `CRAWL-MARKER-NN` line and a
"Next page" link. Tests read these files directly; UI tests get them from
`FixtureSpaForumServer` at `/crawl/page-NN.html`.
