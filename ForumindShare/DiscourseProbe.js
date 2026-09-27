// Safari runs this in the shared page before the share sheet opens
// (NSExtensionJavaScriptPreprocessingFile). Same signals as the app's
// in-browser probe (ForumBrowser.probeFunction).
var DiscourseProbe = function () {};

DiscourseProbe.prototype = {
  run: function (arguments) {
    var result = { url: '', title: '', isDiscourse: false, basePath: '', forumName: '' };
    try {
      var metaContent = function (selector) {
        var element = document.querySelector(selector);
        var content = element ? element.getAttribute('content') : null;
        return typeof content === 'string' ? content.trim() : '';
      };
      var generator = metaContent('meta[name="generator"]');
      var baseUriMeta = document.querySelector('meta[name="discourse-base-uri"]');
      var setup = document.getElementById('data-discourse-setup');
      var setupBase = setup && setup.dataset ? setup.dataset.baseUri : '';
      result.url = window.location.href;
      result.title = document.title || metaContent('meta[property="og:title"]');
      result.isDiscourse = /\bDiscourse\b/i.test(generator) || Boolean(baseUriMeta) || Boolean(setup);
      result.basePath = setupBase || (baseUriMeta ? baseUriMeta.getAttribute('content') || '' : '');
      result.forumName = metaContent('meta[property="og:site_name"]');
    } catch (error) {
      result.url = result.url || String(window.location.href);
    }
    arguments.completionFunction(result);
  },

  finalize: function (arguments) {}
};

var ExtensionPreprocessingJS = new DiscourseProbe();
