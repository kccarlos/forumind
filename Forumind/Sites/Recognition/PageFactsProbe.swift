import Foundation

/// The probe script: collects the declared `PageFactKeys` of a document into
/// the dictionary `PageFacts(probe:fallbackURL:)` reads. Built from the
/// registry's union of keys, so an allowlist of keys decides what leaves the
/// page, not "the first N metas".
enum PageFactsProbe {
    /// A JavaScript expression that evaluates to the probe function. It keeps
    /// a small cache (JSON paths in big datasets are read once per document),
    /// so evaluate it once per document and call the function many times.
    static func expression(keys: PageFactKeys) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(keys)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (() => {
          const keys = \(json);
          const cache = new Map();
          const clip = (value, limit = \(PageFacts.valueLimit)) =>
            typeof value === "string" ? value.trim().slice(0, limit) : "";
          const walk = (value, props) => {
            let current = value;
            for (const prop of props) {
              if (typeof current === "string") {
                try { current = JSON.parse(current); } catch (error) { return ""; }
              }
              if (current === null || typeof current !== "object") return "";
              current = current[prop];
            }
            if (typeof current === "number") return String(current);
            return clip(current);
          };
          const read = (id, element, entry) => {
            const [name, path] = entry.split(":");
            const raw = element.dataset ? element.dataset[name] : undefined;
            if (path === undefined) return clip(raw);
            const cacheKey = id + "/" + entry;
            if (!cache.has(cacheKey)) cache.set(cacheKey, walk(raw, path.split(".")));
            return cache.get(cacheKey);
          };
          return () => {
            const meta = {};
            for (const name of keys.meta) {
              const element = document.querySelector(
                "meta[name=" + JSON.stringify(name) + "], meta[property=" + JSON.stringify(name) + "]"
              );
              if (element) meta[name] = clip(element.getAttribute("content"));
            }
            const links = {};
            for (const rel of keys.links) {
              const element = document.querySelector("link[rel~=" + JSON.stringify(rel) + "]");
              if (element) links[rel] = clip(element.href);
            }
            const elements = {};
            for (const id of Object.keys(keys.elements)) {
              const element = document.getElementById(id);
              if (!element) continue;
              const entry = {};
              for (const key of keys.elements[id]) entry[key] = read(id, element, key);
              elements[id] = entry;
            }
            const matches = keys.selectors.filter(selector => {
              try { return Boolean(document.querySelector(selector)); } catch (error) { return false; }
            });
            const icon = document.querySelector(
              'link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'
            ) || document.querySelector('link[rel~="icon"]');
            return {
              url: window.location.href,
              title: clip(document.title),
              meta: meta,
              links: links,
              elements: elements,
              matches: matches,
              htmlClass: clip(document.documentElement?.className, 2000),
              bodyClass: clip(document.body?.className, 2000),
              iconURL: icon?.href || ""
            };
          };
        })()
        """
    }
}
