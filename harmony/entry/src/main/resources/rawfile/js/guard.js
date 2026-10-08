// H5 阅读器守卫：先在点击捕获阶段阻止章节入口，再用 DOM 特征检测兜底。
(function () {
    function chapterClickTarget(target) {
        var el = target && target.nodeType === 1 ? target : (target ? target.parentElement : null);
        var pattern = /^(第\s*\d+([-–~—]\s*\d+)?\s*[話话]|序章|序|番外.*|Vol\.?\s*\d+)$/;
        for (var depth = 0; el && depth <= 4; depth++, el = el.parentElement) {
            var text = (el.textContent || '').trim();
            if (el.children.length <= 1 && text.length > 0 && text.length <= 24 && pattern.test(text)) {
                return el;
            }
        }
        return null;
    }

    function blockChapterClick(event) {
        var target = chapterClickTarget(event.target);
        if (!target || event.isTrusted !== true) return;
        var text = ((target.textContent || target.innerText) || '').trim();
        event.preventDefault();
        event.stopPropagation();
        if (event.stopImmediatePropagation) event.stopImmediatePropagation();
        try {
            if (window.GM && typeof window.GM.chapterClick === 'function') {
                var getId = window.__cmGestureIds;
                if (!getId) {
                    var nonce = Math.random().toString(36).slice(2);
                    var next = 0;
                    var events = new WeakMap();
                    getId = window.__cmGestureIds = function (event) {
                        if (events.has(event)) return events.get(event);
                        var id = nonce + '-' + (++next);
                        events.set(event, id);
                        return id;
                    };
                }
                window.GM.chapterClick('', text || '', location.href, getId(event));
            }
        } catch (_) {}
    }

    if (!window.__cmChapterClickGuardInstalled) {
        window.__cmChapterClickGuardInstalled = true;
        document.addEventListener('click', blockChapterClick, true);
    }

    function hasReaderImage() {
        return !!document.querySelector('img[src*="c1500x"], img[data-src*="c1500x"]');
    }

    function hasReaderText() {
        var body = document.body;
        if (!body) return false;
        var text = body.innerText || body.textContent || '';
        if (text.indexOf('漫畫觀看') >= 0 || text.indexOf('漫画观看') >= 0) return true;
        var hasPrevious = text.indexOf('上一話') >= 0 || text.indexOf('上一话') >= 0;
        var hasNext = text.indexOf('下一話') >= 0 || text.indexOf('下一话') >= 0;
        return hasPrevious && hasNext;
    }

    function isReaderView() {
        return hasReaderImage() || hasReaderText();
    }

    function checkReader() {
        var now = Date.now();
        if (window.__cmGuardQuietUntil && now < window.__cmGuardQuietUntil) return;
        if (!isReaderView()) {
            window.__cmGuardFired = false;
            return;
        }
        if (window.__cmGuardFired) return;
        window.__cmGuardFired = true;
        window.__cmGuardQuietUntil = now + 3000;
        try {
            if (window.GM && typeof window.GM.onReaderDetected === 'function') {
                window.GM.onReaderDetected();
            }
        } catch (_) {}
    }

    window.__cmReaderGuardCheck = checkReader;
    if (!window.__cmReaderGuardInstalled) {
        window.__cmReaderGuardInstalled = true;
        window.__cmGuardFired = false;
        window.__cmGuardQuietUntil = 0;
        var start = function () {
            checkReader();
            var root = document.documentElement || document.body;
            if (root) {
                new MutationObserver(checkReader).observe(root, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src', 'data-src', 'class']
                });
            }
            setInterval(checkReader, 800);
        };
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
            start();
        }
    } else {
        checkReader();
    }
})();
