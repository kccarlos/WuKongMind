Public responses saved with curl on 2026-11-06 (tests never use the network):

- `hn-item-1.json`: https://hn.algolia.com/api/v1/items/1 (three nested comments)
- `hn-item-2.json`: https://hn.algolia.com/api/v1/items/2 (no comments)
- `hn-large.json`: https://hn.algolia.com/api/v1/items/27016630 (multiple logical pages)
- `hn-search.json`: https://hn.algolia.com/api/v1/search?tags=story&query=sqlite&hitsPerPage=3
- `hn-comments.json`: https://hn.algolia.com/api/v1/search?tags=comment&query=sqlite&hitsPerPage=3
- `hn-latest.json`: https://hn.algolia.com/api/v1/search_by_date?tags=story&hitsPerPage=3
- `hn-html.json` (HTML body in a JSON envelope for the fixture bundler): https://news.ycombinator.com/item?id=1

These are verbatim public responses, retained to test the actual API shapes.
Mutation tests change copies in memory to exercise missing/deleted data and errors.
