import Foundation

/// Discourse's page DOM, as the in-page scripts know it: the topic URL shape,
/// `article[id^="post_"]` inside a `[data-post-number]` wrapper, the author's
/// `a[data-user-card]`, the `.cooked` body and `.topic-list-item` rows. The
/// scripts are the adapter's `capabilities.pageBridge`; the Swift side
/// (`BrowseScript`, `ModerationScript`) only talks to their
/// `window.__forumindBrowse` / `window.__forumindModeration` interfaces.
enum DiscourseDOM {
    /// `window.__forumindBrowse`: scroll to, highlight and read posts. Runs in its own
    /// content world (`BrowseScript.world`).
    static let bridgeInstaller = """
    (() => {
      if (window.__forumindBrowse) return;
      const hiddenAttr = 'data-forumind-hidden';
      const mark = 'forumind-highlight';
      const state = { numbers: [], topic: null, bottomInset: 0, flash: null };
      const flashMark = 'forumind-flash';
      function topicID() {
        const match = location.pathname.match(/\\/t\\/(?:[^/]+\\/)?(\\d+)/);
        return match ? match[1] : null;
      }
      function ensureStyle() {
        if (document.getElementById('forumind-browse-style')) return;
        const style = document.createElement('style');
        style.id = 'forumind-browse-style';
        // Brand blue, as a bar and a light tint: readable on light and dark
        // Discourse themes alike.
        style.textContent = [
          'article.' + mark + ' { box-shadow: inset 4px 0 0 #3A5BE0 !important;',
          '  background-color: rgba(58, 91, 224, 0.10) !important; border-radius: 6px;',
          '  transition: background-color 0.3s ease, box-shadow 0.3s ease; }',
          '@media (prefers-color-scheme: dark) { article.' + mark + ' {',
          '  box-shadow: inset 4px 0 0 #7B93FF !important;',
          '  background-color: rgba(123, 147, 255, 0.16) !important; } }'
        ].join('\\n');
        (document.head || document.documentElement).appendChild(style);
      }
      // Stroke in 0.2 s, hold 1.5 s, fade 0.6 s (2.3 s in all).
      function ensureFlashStyle() {
        if (document.getElementById('forumind-flash-style')) return;
        const style = document.createElement('style');
        style.id = 'forumind-flash-style';
        style.textContent = [
          'article.' + flashMark + ' { outline-style: solid; outline-width: var(--forumind-flash-width, 2px);',
          '  outline-offset: calc(-1 * var(--forumind-flash-width, 2px)); outline-color: transparent;',
          '  animation: forumind-flash 2.3s linear forwards; }',
          '@keyframes forumind-flash { 0% { outline-color: transparent; }',
          '  8.7% { outline-color: var(--forumind-flash-color); }',
          '  73.9% { outline-color: var(--forumind-flash-color); }',
          '  100% { outline-color: transparent; } }'
        ].join('\\n');
        (document.head || document.documentElement).appendChild(style);
      }
      function applyFlash() {
        const flash = state.flash;
        if (!flash || flash.done) return;
        const article = shownPost(flash.number);
        if (!article) return;
        flash.done = true;
        ensureFlashStyle();
        const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
        article.style.setProperty('--forumind-flash-color', dark ? flash.dark : flash.light);
        article.style.setProperty('--forumind-flash-width', flash.width + 'px');
        article.classList.remove(flashMark);
        void article.offsetWidth;
        article.classList.add(flashMark);
        setTimeout(() => article.classList.remove(flashMark), 2400);
      }
      const numberOf = article => parseInt(article.id.slice(5), 10);
      const isHidden = article => (article.closest('[data-post-number]') || article).hasAttribute(hiddenAttr);
      function authorOf(article) {
        const author = article.querySelector('a[data-user-card]');
        return author ? (author.dataset.userCard || '') : '';
      }
      function textOf(article) {
        const cooked = article.querySelector('.cooked');
        return cooked ? cooked.innerText.replace(/[ \\t]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim() : '';
      }
      // A rendered, shown post: Discourse leaves cloaked placeholders
      // without a body for posts far off screen.
      function shownPost(number) {
        const article = document.getElementById('post_' + number);
        if (!article || isHidden(article)) return null;
        return article;
      }
      // Discourse's fixed header covers the top of the viewport.
      function headerBottom() {
        const header = document.querySelector('.d-header-wrap') || document.querySelector('.d-header');
        if (!header) return 0;
        const rect = header.getBoundingClientRect();
        return rect.top <= 1 ? Math.max(0, rect.bottom) : 0;
      }
      function highlighted() {
        return Array.from(document.querySelectorAll('article.' + mark))
          .filter(article => !isHidden(article))
          .map(numberOf)
          .filter(number => number > 0);
      }
      function visible() {
        const top = headerBottom();
        const bottom = window.innerHeight - state.bottomInset;
        const posts = [];
        document.querySelectorAll('article[id^="post_"]').forEach(article => {
          if (isHidden(article)) return;
          const rect = article.getBoundingClientRect();
          if (rect.height === 0 || rect.bottom <= top || rect.top >= bottom) return;
          const number = numberOf(article);
          const username = authorOf(article);
          if (!(number > 0) || !username) return;
          posts.push({ number, username, excerpt: textOf(article).replace(/\\s+/g, ' ').slice(0, 160) });
        });
        return posts;
      }
      function apply() {
        // Highlights belong to one topic; an in-page route to another drops them.
        if (state.topic && state.topic !== topicID()) {
          state.numbers = [];
          state.topic = null;
        }
        const wanted = new Set(state.numbers);
        document.querySelectorAll('article.' + mark).forEach(article => {
          if (!wanted.has(numberOf(article)) || isHidden(article)) article.classList.remove(mark);
        });
        if (wanted.size > 0) ensureStyle();
        wanted.forEach(number => {
          const article = shownPost(number);
          // Only when missing: re-adding would queue a mutation every frame.
          if (article && !article.classList.contains(mark)) article.classList.add(mark);
        });
        applyFlash();
        reportSoon();
      }
      let scheduled = false;
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; apply(); });
      }
      let reportTimer;
      let lastReport = '';
      function reportSoon() {
        clearTimeout(reportTimer);
        reportTimer = setTimeout(report, 250);
      }
      function report() {
        if (!topicID()) return;
        const body = { url: location.href, visible: visible().map(post => post.number), highlighted: highlighted() };
        const key = JSON.stringify(body);
        if (key === lastReport) return;
        lastReport = key;
        window.webkit?.messageHandlers?.forumindBrowse?.postMessage(body);
      }
      function start() {
        // Class changes too: Discourse re-renders a post's element in place.
        new MutationObserver(schedule).observe(document.documentElement, {
          childList: true, subtree: true, attributes: true, attributeFilter: ['class']
        });
        window.addEventListener('scroll', reportSoon, { passive: true });
        window.addEventListener('resize', reportSoon, { passive: true });
        schedule();
      }
      window.__forumindBrowse = {
        scrollToPost(number, smooth) {
          const article = document.getElementById('post_' + number);
          if (!article) return 'missing';
          if (isHidden(article)) return 'hidden';
          const rect = article.getBoundingClientRect();
          if (rect.height === 0) return 'missing';
          const top = window.scrollY + rect.top - headerBottom() - 8;
          window.scrollTo({ top: Math.max(0, top), behavior: smooth ? 'smooth' : 'auto' });
          reportSoon();
          return 'shown';
        },
        highlight(numbers, flash) {
          state.numbers = (numbers || []).filter(number => number > 0);
          state.topic = topicID();
          if (flash && flash.number > 0) state.flash = { ...flash, done: false };
          apply();
          return highlighted();
        },
        clearHighlight() {
          state.numbers = [];
          state.topic = null;
          apply();
          return [];
        },
        visible,
        postText(number) {
          const article = shownPost(number);
          if (!article) return null;
          const text = textOf(article);
          const username = authorOf(article);
          return text && username ? { number, username, text } : null;
        },
        setInsets(bottom) {
          state.bottomInset = Math.max(0, bottom || 0);
          reportSoon();
          return true;
        }
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
      else start();
    })();
    """

    /// `window.__forumindModeration`: hides blocked and filtered posts. Discourse wraps
    /// each post in `[data-post-number]` around `article[id^=post_]`; the author is the
    /// first `a[data-user-card]` inside it.
    static let moderationInstaller = """
    (() => {
      if (window.__forumindModeration) return;
      const state = { users: new Set(), words: [], posts: {} };
      const attr = 'data-forumind-hidden';
      function ensureStyle() {
        if (document.getElementById('forumind-moderation-style')) return;
        const style = document.createElement('style');
        style.id = 'forumind-moderation-style';
        style.textContent = '[' + attr + '] { display: none !important; }';
        (document.head || document.documentElement).appendChild(style);
      }
      function topicID() {
        const match = location.pathname.match(/\\/t\\/(?:[^/]+\\/)?(\\d+)/);
        return match ? match[1] : null;
      }
      let hasHidden = false;
      function apply() {
        ensureStyle();
        const hidden = state.posts[topicID()] || [];
        const active = state.users.size > 0 || state.words.length > 0 || hidden.length > 0;
        if (!active) {
          // Nothing to hide: undo earlier hiding once, then stay idle.
          if (hasHidden) {
            document.querySelectorAll('[' + attr + ']').forEach(element => element.removeAttribute(attr));
            hasHidden = false;
          }
          return;
        }
        hasHidden = true;
        const checksText = state.words.length > 0;
        document.querySelectorAll('article[id^="post_"]').forEach(article => {
          const wrapper = article.closest('[data-post-number]') || article;
          const author = article.querySelector('a[data-user-card]');
          const name = author ? (author.dataset.userCard || '').toLowerCase() : '';
          const number = parseInt(article.id.slice(5), 10);
          const cooked = checksText ? article.querySelector('.cooked') : null;
          // textContent: no layout pass on every page change.
          const text = cooked ? cooked.textContent.toLowerCase() : '';
          const hide = (name && state.users.has(name))
            || hidden.includes(number)
            || (text && state.words.some(word => text.includes(word)));
          if (hide) wrapper.setAttribute(attr, '');
          else wrapper.removeAttribute(attr);
        });
        // Topic lists: topics started by a hidden user.
        document.querySelectorAll('.topic-list-item').forEach(row => {
          const starter = row.querySelector('.posters a[data-user-card]');
          const name = starter ? (starter.dataset.userCard || '').toLowerCase() : '';
          if (name && state.users.has(name)) row.setAttribute(attr, '');
          else row.removeAttribute(attr);
        });
      }
      let scheduled = false;
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; apply(); });
      }
      function start() {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
        schedule();
      }
      window.__forumindModeration = {
        update(config) {
          state.users = new Set((config.users || []).map(name => name.toLowerCase()));
          state.words = (config.words || []).map(word => word.toLowerCase());
          state.posts = config.posts || {};
          schedule();
        },
        // The posts on screen, for the report sheet.
        posts() {
          return Array.from(document.querySelectorAll('article[id^="post_"]'))
            .filter(article => !(article.closest('[data-post-number]') || article).hasAttribute(attr))
            .map(article => {
              const author = article.querySelector('a[data-user-card]');
              const cooked = article.querySelector('.cooked');
              return {
                number: parseInt(article.id.slice(5), 10),
                username: author ? (author.dataset.userCard || '') : '',
                excerpt: cooked ? cooked.innerText.replace(/\\s+/g, ' ').trim().slice(0, 160) : ''
              };
            })
            .filter(post => post.username && post.number > 0);
        }
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
      else start();
    })();
    """
}
