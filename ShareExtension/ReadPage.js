// ReadPage.js
// What Safari already loaded, handed to the share sheet (`NSExtensionJavaScriptPreprocessingFile`).
//
// Read from the live page rather than fetched again, because the page somebody is looking
// at is the one their own browser was allowed to load: a shop that turns away the app's
// fetch, or draws its photographs only after a script runs, has already shown all of it here.
// Only what the page publishes about itself is read — its title, canonical address, Open
// Graph and product tags, its schema.org JSON-LD, and its largest pictures — and every part
// is capped, because the result crosses into an extension with a hard memory limit. See
// docs/share-extension.md.

var ReadPage = function() {};

ReadPage.prototype = {
    run: function(args) {
        var blockLimit = 65536;
        var totalLimit = 262144;
        var result = { schema: 1, url: document.URL, title: document.title || "" };

        var canonical = document.querySelector("link[rel='canonical']");
        if (canonical && canonical.href) { result.canonical = canonical.href; }

        // Open Graph, the product tags beside it, Twitter's equivalents and the plain
        // description — first occurrence wins, as it does in `PageMetadataParser`.
        var meta = {};
        var tags = document.getElementsByTagName("meta");
        for (var i = 0; i < tags.length && i < 400; i++) {
            var key = (tags[i].getAttribute("property") || tags[i].getAttribute("name") || "").toLowerCase();
            var value = tags[i].getAttribute("content");
            if (!key || !value || meta[key] !== undefined) { continue; }
            if (/^(og|product|twitter):/.test(key) || key === "description") {
                meta[key] = value.slice(0, 2048);
            }
        }
        result.meta = meta;

        // Every JSON-LD block as raw text: parsing belongs to `ProductPage`, the same code
        // that reads a page the app fetched itself.
        var ld = [];
        var total = 0;
        var scripts = document.querySelectorAll("script[type='application/ld+json']");
        for (var j = 0; j < scripts.length && ld.length < 12; j++) {
            var text = scripts[j].textContent || "";
            if (text.length > blockLimit || total + text.length > totalLimit) { continue; }
            total += text.length;
            ld.push(text);
        }
        result.jsonLD = ld;

        // The largest pictures actually drawn, which is what a shop that renders its gallery
        // with a script has and its markup does not.
        var seen = {};
        var images = [];
        var all = document.images;
        for (var k = 0; k < all.length && k < 600; k++) {
            var image = all[k];
            var source = image.currentSrc || image.src || "";
            if (source.indexOf("https://") !== 0 || seen[source]) { continue; }
            if (image.naturalWidth < 300 || image.naturalHeight < 300) { continue; }
            seen[source] = true;
            images.push({ url: source, area: image.naturalWidth * image.naturalHeight });
        }
        images.sort(function(a, b) { return b.area - a.area; });
        result.images = images.slice(0, 10).map(function(entry) { return entry.url; });

        args.completionFunction(result);
    },

    finalize: function(args) {}
};

var ExtensionPreprocessingJS = new ReadPage;
