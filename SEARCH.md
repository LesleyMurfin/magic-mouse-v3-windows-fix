# Getting found as "Magic Mouse 2024 (v3) Windows driver"

Google linked the bare repo — not this site — and answer engines had no structured facts to quote.
Searches for the sibling project ("Magic Tray windows app") returned Etsy desk-tray accessories.

| Problem | Cause | Fixed by |
| --- | --- | --- |
| Repo outranked the site | Site had one thin page, no page set to rank | Five keyword-targeted pages: `/`, `install.html`, `scroll-fix.html`, `battery.html`, `faq.html` |
| No rich result, no AI citation | Zero structured data | `SoftwareApplication` + `WebSite` + `Organization` + per-page `WebPage`/`BreadcrumbList`, `HowTo` on `install.html`, `FAQPage` on `faq.html` |
| Wrong query targets | Title said "scroll — KMDF" | Titles, `h1`s, and leads now carry "Magic Mouse 2024 (v3) Windows driver", "Magic Mouse v3 Windows driver", "PID 0323", "Windows 11" |
| Sitemap errors | Sitemap listed a `github.com` URL — invalid, another host | Sitemap lists this site's URLs only |
| Answer engines guessing | No machine-readable summary | `llms.txt` with quick answers, hardware matrix, and canonical facts |
| Battery claims wrong | Page never said who reads battery | Every page states battery percentage is the Magic Tray app reading HID Input `0x90` COL02 — not this driver |

## What is already done in the repo

- `docs/*.html` — canonicals, `og:`/`twitter:` cards, `og.png` (1200x630),
  `robots` meta with `max-snippet:-1,max-image-preview:large`, one `h1` per page, internal
  cross-links with descriptive anchor text.
- `docs/robots.txt` — explicit `Allow: /` stanzas for 19 search and answer-engine crawlers
  (GPTBot, OAI-SearchBot, ClaudeBot, PerplexityBot, Google-Extended, Applebot, Bingbot, CCBot,
  and others). A user-agent group overrides the wildcard group entirely, so any future
  `Disallow:` line must be repeated inside every stanza.
- `docs/sitemap.xml` — the five pages plus `llms.txt`, with `lastmod`. `404.html` is `noindex`
  and deliberately absent.
- `docs/llms.txt` — quick answers, PID matrix, canonical facts, and the "not this" list
  (not v1/v2, not Magic Utilities, not the Magic Tray desk accessory sold on Etsy).
- `docs/26dfa1cbdec3bc78636043b6bc6466fa.txt` — IndexNow key. Keep this file; deleting it
  breaks URL submission. The five page URLs plus the sitemap were submitted and accepted
  (HTTP 202) on 2026-09-04.
- `README.md` — the searched phrase is the H1, the site is linked in the first lines.
- Repo description, homepage, and topics name the device, the fix, and the OS.
- The sibling site (`LesleyMurfin/magic-tray`) links here with keyword-bearing anchor text,
  which is the only inbound-link signal under our control.

## What only the repo owner can do

1. **Google Search Console** — add `https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/`
   as a URL-prefix property. GitHub Pages cannot serve a DNS TXT record, so use the HTML file
   method: drop the `google*.html` file Google issues into `docs/`, commit, then click Verify.
2. **Submit the sitemap** — Search Console → Sitemaps → `sitemap.xml`.
3. **Request indexing** — URL Inspection, one request per page. Editing the repo does not force
   a recrawl; this is what replaces a stale cached title.
4. **Bing Webmaster Tools** — same two steps. Bing feeds several AI answer engines. IndexNow
   already pings Bing and Yandex; a verified property still helps.
5. **Social preview image** — GitHub only accepts it through the web UI:
   Settings → General → Social preview → upload `docs/og.png`. Do the same on `magic-tray`.
6. **Consider a custom domain.** `lesleymurfin.github.io/…` is a path on a shared subdomain,
   which is why `github.com` outranks it. A domain with a `docs/CNAME` file would own its own
   authority. Changing it means updating every `canonical`, `og:url`, JSON-LD `@id`, sitemap
   `<loc>`, and the IndexNow `keyLocation`.

## Re-submitting URLs after a content change

```bash
curl -s -X POST https://api.indexnow.org/indexnow \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d '{"host":"lesleymurfin.github.io",
       "key":"26dfa1cbdec3bc78636043b6bc6466fa",
       "keyLocation":"https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/26dfa1cbdec3bc78636043b6bc6466fa.txt",
       "urlList":["https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/"]}'
```

HTTP 202 means accepted. It is not a ranking signal — it only shortens discovery time.
